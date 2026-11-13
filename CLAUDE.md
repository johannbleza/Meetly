# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Meetly is a macOS meeting assistant (SwiftUI + AppKit, Xcode project, Apple frameworks plus one SPM dependency: WhisperKit): live on-device transcription of mic + system audio, a floating always-on-top overlay with live captions and AI Q&A during a call, and post-meeting AI summaries/action items in the main window.

## Build

```sh
xcodebuild -project Meetly.xcodeproj -scheme Meetly build
```

Single target/scheme `Meetly`. No test targets exist. Deployment target is macOS 26.5 (uses the new `SpeechAnalyzer`/`SpeechTranscriber` and FoundationModels APIs). Usage-description strings live in `INFOPLIST_KEY_*` build settings, not a plist file.

**AI sign-in:** No API keys. Claude and Codex use the user's own subscription through the official `claude` and `codex` command-line tools, which must be installed and signed in. Settings live in `UserDefaults` via `Services/AppSettings.swift`.

## Architecture

`SessionManager` (`Services/SessionManager.swift`, `@MainActor @Observable`) is the hub: meeting state machine (idle/recording/paused/summarizing), overlay presentation state, chat messages, and all wiring between audio → transcription → SwiftData → AI. Starting a meeting hides the main window and shows the overlay; stopping reverses it.

**Audio pipeline:** `AudioCaptureService` (facade) owns `MicrophoneCapture` (AVAudioEngine tap) and `SystemAudioCapture` (ScreenCaptureKit, audio-only). Buffers flow through `AudioSourceRouter` into `LiveTranscriptionService`, which runs **two independent `TranscriptionChannel` instances** — one per source. "You" vs "Speaker" attribution is source-based (mic → `.me`, system audio → `.other`), not diarization.

**Transcription engines:** `TranscriptionEngine` in settings picks `WhisperChannel` (default; `Services/Whisper/`, on-device via WhisperKit) or `AppleSpeechChannel`. Whisper doesn't stream: `WhisperSegmenter` cuts audio into utterances by energy, re-decoding the growing utterance for live captions; `PartialTextStabilizer` only shows words two decodes agree on, so captions grow instead of rewriting. Both channels share one `WhisperRuntime`, which serializes decodes. Models are installed ahead of time from Settings (`WhisperModelStore`); if the selected model is missing or fails to load, the meeting falls back to Apple Speech with a warning rather than downloading or failing at start.

**AI:** `AIService` fronts three providers (`AIProvider`): Claude (default) and Codex, which launch the signed-in command-line tools (`Services/CLIAgents/`, model from settings), and on-device Apple Intelligence (`Services/FoundationModels/`). Apple Intelligence can't read images, so image questions route to whichever command-line tool is installed. Per-session controllers (`MeetingQAController`, `MeetingSummaryController`, `ActionItemsController`) each construct their own `AIService` and build prompts via `MeetingContextBuilder`.

**Persistence:** SwiftData only. `@Model` types in `Models/`: `MeetingSession` → cascade `TranscriptSegment` + `MeetingSummary` → cascade `ActionItem`, and cascade `QAMessage` (Ask AI history: overlay questions during the call and detail-page questions, saved as question/answer pairs on success; errors aren't saved). Final transcript segments are saved immediately as they arrive.

**Overlay:** `Overlay/OverlayPanelController` hosts a borderless floating `NSPanel` (all Spaces, forced dark, ⌘V image paste). Global hot key ⌘\ toggles it (Carbon, `OverlayKeyboardShortcutController`). `ScreenShareExclusion` sets `sharingType = .none` on all windows so Meetly is invisible in screen shares (toggleable in settings).

**Screenshots:** "Ask about screen" in the overlay takes one full-size frame from the meeting-audio `SCStream` (temporarily raising its 2×2 resolution) and sends it to `askQuestion`. Don't use `SCScreenshotManager`: the picker's approval only covers the stream, so screenshots fail Screen Recording TCC. It opens the share picker if meeting audio isn't on. The panel goes to alpha 0 during capture because recent macOS versions don't reliably honor `sharingType = .none` for ScreenCaptureKit.

**Meeting detection:** `Services/MeetingDetection/` needs no calendar. `AudioProcessMonitor` polls Core Audio's per-process objects for which apps hold the mic, excluding Meetly's own PID. `MeetingDetector` treats the known call apps in `MeetingApp.all` (Teams, Zoom, Webex, Slack, FaceTime, …) as calls; for browsers (`MeetingBrowser`: Chrome, Safari, Edge, Brave, Arc, …) it asks `BrowserMeetingProbe` to match open tab URLs against known meeting sites (Automation permission). Any other app holding the mic, or a browser with no matching tab, still gets a generic "X is using your microphone" prompt (`OtherMicApp`, which skips system services and recording/dictation apps). Confirmed calls win over generic ones. `SessionManager.reconcileDetection()` turns that into the start prompt in the idle overlay and the auto-stop countdown. It's idempotent and runs after every poll.

## Critical constraints (violating these reintroduces fixed bugs)

- **PCM buffers never touch the MainActor.** The capture-thread → router → speech-channel path uses `nonisolated(unsafe)` callbacks and lock-guarded `@unchecked Sendable` types (`AppleSpeechChannel`, `LiveTranscriptionService.ChannelStorage`). Don't add MainActor hops to the audio path.
- **The overlay panel window is a fixed-size transparent canvas** — fold/expand is a pure SwiftUI animation inside it; `updateForPresentation` deliberately never resizes the `NSPanel`. Resizing the window reintroduces clipping/jitter.
- **System audio capture must go through `SCContentSharingPicker`**, never `SCShareableContent` — programmatic capture re-triggers the Screen Recording TCC dialog even when granted. The picker must be presented *before* hiding the main window (it needs a key window or it silently cancels); see `SessionManager.prepareForContentSharingPicker()`.
- **SwiftData migrations are destructive**: `MeetlyApp` deletes and recreates the store if migration fails. Add new model fields as optionals with a defaulting accessor (see `MeetingSession.isArchived`/`isArchivedValue`) to avoid wiping user data.
- The system speech channel is eager-started before any system audio arrives to avoid a cold-start transcription gap; `feedSystemBuffer` lazily restarts it if missing.
- Mic transcripts matching recent meeting audio are dropped as speaker bleed (`MicBleedFilter`, applied in `SessionManager`). This compares transcripts on purpose: earlier buffer-level gates (`MicEchoGate`, RMS thresholds) also cut the user's own speech.
- Consecutive final transcripts from the same speaker within 3s are merged into one bubble (`SessionManager.shouldMergeTranscript`).
- **Detected calls prompt instead of starting a recording**, because system audio needs a click on the share picker. Auto-stop always shows a cancellable countdown because mic release is only an inferred end of call, and it only applies to recordings that overlapped a detected call. It must not fire during `startMeeting()`: `stopMeeting()` removes the picker observer, which would leave the picker continuation unresumed.
- **Meetings with no transcript are deleted when they stop** (`SessionManager.stopMeeting`), so the session row created at start never shows up as an empty meeting.
- **Continuing a meeting** (`SessionManager.continueMeeting`, "Continue Meeting" in the detail header) records into the existing session. The time between recordings goes in `MeetingSession.continuationGapDuration` and is left out of `duration`. Stopping with no new segments puts `endedAt` and the gap back as they were and keeps the old summary; otherwise the summary is replaced, not duplicated.
- **Silent recordings stop themselves** (`SessionManager.reconcileIdleStop`, `AppSettings.idleRecordingStopMinutes`), which covers recordings with no detected call. Transcripts and user actions restart the timer. It skips paused recordings and detected calls, because a call can be quiet for long stretches, and it also must not fire while the share picker is open.
- **App sandbox is off** because a sandboxed app's child processes inherit the sandbox and can't reach the CLI tools' sign-ins. Keep the audio-input entitlement in `Meetly/Meetly.entitlements`. `LegacyContainerMigration` copies data out of the old container on first launch.
- **Store data under `AppStoragePaths`**, never at SwiftData's or Application Support's default location. Unsandboxed, those are shared with other apps, and `MeetlyApp` deletes the store when migration fails.
- **Transcripts are untrusted input to the CLI tools**: anyone on a call can speak instructions into them. `CLIAgent` must keep shell and file tools off, ignore user settings, MCP servers and hooks, run in an empty temp directory, and not save session history. Web search is the only tool allowed. It also strips API-key variables from the environment so usage stays on the subscription.
