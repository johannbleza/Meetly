# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Meetly is a macOS meeting assistant (SwiftUI + AppKit, Xcode project, no SPM dependencies — Apple frameworks only): live on-device transcription of mic + system audio, a floating always-on-top overlay with live captions and AI Q&A during a call, and post-meeting AI summaries/action items in the main window.

## Build

```sh
xcodebuild -project Meetly.xcodeproj -scheme Meetly build
```

Single target/scheme `Meetly`. No test targets exist. Deployment target is macOS 26.5 (uses the new `SpeechAnalyzer`/`SpeechTranscriber` and FoundationModels APIs). Usage-description strings live in `INFOPLIST_KEY_*` build settings, not a plist file.

**API key:** Gemini requires `GEMINI_API_KEY`, read by `Services/DotEnv.swift` from env or a gitignored `.env` (dev convenience). On first launch it is migrated into the Keychain (`GeminiKeyStore`), which is the real runtime source. Non-secret settings live in `UserDefaults` via `Services/AppSettings.swift`.

## Architecture

`SessionManager` (`Services/SessionManager.swift`, `@MainActor @Observable`) is the hub: meeting state machine (idle/recording/paused/summarizing), overlay presentation state, chat messages, and all wiring between audio → transcription → SwiftData → AI. Starting a meeting hides the main window and shows the overlay; stopping reverses it.

**Audio pipeline:** `AudioCaptureService` (facade) owns `MicrophoneCapture` (AVAudioEngine tap) and `SystemAudioCapture` (ScreenCaptureKit, audio-only). Buffers flow through `AudioSourceRouter` into `LiveTranscriptionService`, which runs **two independent `AppleSpeechChannel` instances** — one per source. "You" vs "Speaker" attribution is source-based (mic → `.me`, system audio → `.other`), not diarization.

**AI:** `AIService` fronts two providers (`AIProvider`): on-device Apple Intelligence (`Services/FoundationModels/`, default) and Gemini via raw REST (`Services/Gemini/`, model from settings, default `gemini-2.5-flash`). Image attachments always route to Gemini regardless of the selected provider. Per-session controllers (`MeetingQAController`, `MeetingSummaryController`, `ActionItemsController`) each construct their own `AIService` and build prompts via `MeetingContextBuilder`.

**Persistence:** SwiftData only. `@Model` types in `Models/`: `MeetingSession` → cascade `TranscriptSegment` + `MeetingSummary` → cascade `ActionItem`. Final transcript segments are saved immediately as they arrive.

**Overlay:** `Overlay/OverlayPanelController` hosts a borderless floating `NSPanel` (all Spaces, forced dark, ⌘V image paste). Global hot key ⌘\ toggles it (Carbon, `OverlayKeyboardShortcutController`). `ScreenShareExclusion` sets `sharingType = .none` on all windows so Meetly is invisible in screen shares (toggleable in settings).

## Critical constraints (violating these reintroduces fixed bugs)

- **PCM buffers never touch the MainActor.** The capture-thread → router → speech-channel path uses `nonisolated(unsafe)` callbacks and lock-guarded `@unchecked Sendable` types (`AppleSpeechChannel`, `LiveTranscriptionService.ChannelStorage`). Don't add MainActor hops to the audio path.
- **The overlay panel window is a fixed-size transparent canvas** — fold/expand is a pure SwiftUI animation inside it; `updateForPresentation` deliberately never resizes the `NSPanel`. Resizing the window reintroduces clipping/jitter.
- **System audio capture must go through `SCContentSharingPicker`**, never `SCShareableContent` — programmatic capture re-triggers the Screen Recording TCC dialog even when granted. The picker must be presented *before* hiding the main window (it needs a key window or it silently cancels); see `SessionManager.prepareForContentSharingPicker()`.
- **SwiftData migrations are destructive**: `MeetlyApp` deletes and recreates the store if migration fails. Add new model fields as optionals with a defaulting accessor (see `MeetingSession.isArchived`/`isArchivedValue`) to avoid wiping user data.
- The system speech channel is eager-started before any system audio arrives to avoid a cold-start transcription gap; `feedSystemBuffer` lazily restarts it if missing.
- Consecutive final transcripts from the same speaker within 3s are merged into one bubble (`SessionManager.shouldMergeTranscript`).
- App sandbox is on (`Meetly/Meetly.entitlements`): audio input, user-selected file read-write (Markdown export), network client (Gemini).
