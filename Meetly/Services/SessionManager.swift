import AppKit
import AVFoundation
import Foundation
import SwiftData

enum MeetingState: Equatable {
    case idle
    case recording
    case paused
    case summarizing
}

enum OverlayPresentation: Equatable {
    case hidden
    case folded
    case expanded
}

/// Where the overlay lives: grown out of the notch, or pulled out into its own floating panel.
enum OverlayDock: Equatable {
    case notch
    case floating
}

@MainActor
@Observable
final class SessionManager {
    private(set) var state: MeetingState = .idle
    private(set) var currentSession: MeetingSession?

    /// The meeting being recorded or summarized. It can't be deleted or archived until that
    /// finishes, because transcripts and the summary are still being written into it.
    func isInUse(_ session: MeetingSession) -> Bool {
        currentSession?.id == session.id
    }
    private(set) var chatMessages: [ChatMessage] = []
    /// In-progress speech, one caption per speaker, so two people talking don't overwrite each other.
    private(set) var liveCaptions: [LiveCaption] = []
    private(set) var transcriptHistory: [String] = []
    private(set) var activeQuestion: String?
    private(set) var activeQuestionImages: [ChatImageAttachment] = []
    private(set) var activeAnswer: String?
    /// Overlay Q&A thread; cleared when the overlay chat is closed.
    private(set) var overlayQAMessages: [ChatMessage] = []
    private(set) var isAwaitingAnswer = false
    private(set) var isCapturingScreen = false
    private(set) var errorMessage: String?
    private(set) var warningMessage: String?
    private(set) var needsSystemAudioPicker = false
    private(set) var isSystemAudioEnabled = false
    private(set) var isMicrophoneMuted = false
    private(set) var sessionStartedAt: Date?
    private(set) var overlayPresentation: OverlayPresentation = .hidden
    /// Every meeting starts in the notch; pulling the overlay out lasts until the meeting ends.
    private(set) var overlayDock: OverlayDock = .notch
    private(set) var aiProviderSelection: AIProvider = AppSettings.aiProvider
    private(set) var lastCompletedSessionID: UUID?
    /// A call waiting for the user to choose whether to record it.
    private(set) var detectedMeetingPrompt: DetectedMeeting?
    /// When the recording will stop on its own because the call ended.
    private(set) var autoStopDeadline: Date?
    /// When the recording will stop on its own because nothing has been heard for a while.
    private(set) var idleStopDeadline: Date?

    private let audioCaptureService = AudioCaptureService()
    private let audioSourceRouter = AudioSourceRouter()
    private let transcriptionService = LiveTranscriptionService()
    private let aiService = AIService()
    private let meetingDetector = MeetingDetector()

    private var modelContext: ModelContext?
    private var partialMessageIDs: [Speaker: UUID] = [:]
    private var micBleedFilter = MicBleedFilter()
    private var heldMicFinals: [HeldMicFinal] = []
    /// Newest meeting audio already covered by a final transcript, on the `systemUptime` clock.
    private var transcribedSystemSpeechUptime: TimeInterval?
    private var lastFinalTranscriptAt: [Speaker: Date] = [:]
    private var pausedAt: Date?
    private var accumulatedPausedDuration: TimeInterval = 0
    private var overlayQAConversationID = UUID()
    private var isStartingMeeting = false
    /// The call this recording stops with. Stays nil for meetings without a call, such as in-person ones.
    private var autoStopSource: MeetingSource?
    private var autoStopTask: Task<Void, Never>?
    private var idleStopTask: Task<Void, Never>?
    /// Last transcript or user action in the current recording.
    private var lastRecordingActivityAt = Date()
    private var isPickingSystemAudio = false
    /// A call the user declined or stopped recording, so it doesn't prompt again.
    private var suppressedSource: MeetingSource?
    private var overlayShownForPrompt = false
    /// Set while recording into an earlier meeting, so stopping with nothing new can put it back as it was.
    private var continuation: Continuation?
    #if DEBUG
    /// Scripted overlay states for tuning the notch (`NotchDemoDriver`); detection stays out of the way.
    var isNotchDemoActive = false
    private var notchDemoTask: Task<Void, Never>?
    #endif

    private let transcriptMergePauseThreshold: TimeInterval = 3
    /// Meeting audio older than this can't explain a new mic transcript, even if its own transcript is late.
    private let micBleedOverlapWindow: TimeInterval = 4
    /// Longest a mic transcript waits for the meeting-audio transcript it might duplicate.
    private let micHoldDuration: TimeInterval = 5
    /// Matches `WhisperSegmenter`'s end-of-speech silence: quiet this long means the utterance is over.
    private let systemUtteranceEndSilence: TimeInterval = 0.7
    private let autoStopCountdown: TimeInterval = 15
    /// Longer than the call-ended countdown: nothing else suggests the user has left.
    private let idleStopCountdown: TimeInterval = 60

    private struct Continuation {
        let segmentCountAtStart: Int
        let previousEndedAt: Date?
        let previousGapDuration: TimeInterval?
    }

    private struct HeldMicFinal {
        let text: String
        let receivedAt: Date
    }

    var isMeetingActive: Bool {
        state == .recording || state == .paused
    }

    var isOverlayVisible: Bool {
        overlayPresentation != .hidden
    }

    var sessionElapsedTime: TimeInterval {
        guard let sessionStartedAt else { return 0 }
        var elapsed = Date().timeIntervalSince(sessionStartedAt) - accumulatedPausedDuration
        if let pausedAt {
            elapsed -= Date().timeIntervalSince(pausedAt)
        }
        return max(0, elapsed)
    }

    var isAIAvailable: Bool {
        aiService.isAvailable
    }

    var aiProvider: AIProvider {
        aiProviderSelection
    }

    func setAIProvider(_ provider: AIProvider) {
        aiProviderSelection = provider
        AppSettings.aiProvider = provider
    }

    var aiAvailabilityMessage: String? {
        aiService.availabilityMessage
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        meetingDetector.onUpdate = { [weak self] in
            self?.reconcileDetection()
        }
        meetingDetector.start()
    }

    func toggleOverlay() {
        if overlayPresentation == .hidden {
            showOverlay()
        } else {
            hideOverlay()
        }
    }

    func handleOverlayShortcut() {
        switch state {
        case .idle, .recording, .paused:
            if overlayPresentation != .hidden, !OverlayPanelController.shared.isOnActiveScreen {
                // It's open on another display: bring it here instead of hiding it.
                showOverlay(followingPointer: true)
            } else {
                toggleOverlay()
            }
        case .summarizing:
            break
        }
    }

    func showOverlay(followingPointer: Bool = false) {
        overlayPresentation = .expanded
        OverlayPanelController.shared.show(followingPointer: followingPointer)
        OverlayPanelController.shared.updateForPresentation(.expanded)
    }

    func hideOverlay() {
        // Hiding the overlay while it's asking counts as answering "not now".
        if let detectedMeetingPrompt {
            suppressedSource = detectedMeetingPrompt.source
            self.detectedMeetingPrompt = nil
            overlayShownForPrompt = false
        }
        overlayPresentation = .hidden
        OverlayPanelController.shared.hide()
    }

    func foldOverlay() {
        guard isMeetingActive, overlayDock == .floating else { return }
        overlayPresentation = .folded
        OverlayPanelController.shared.updateForPresentation(.folded)
    }

    func expandOverlay() {
        guard isMeetingActive, overlayDock == .floating else { return }
        overlayPresentation = .expanded
        OverlayPanelController.shared.updateForPresentation(.expanded)
    }

    /// Pulls the overlay out of the notch into the floating panel, e.g. to type a follow-up.
    func popOutOverlay() {
        guard overlayDock == .notch else { return }
        overlayPresentation = .expanded
        OverlayPanelController.shared.popOut()
    }

    /// Flies the floating overlay back into the notch.
    func dockOverlay() {
        guard overlayDock == .floating else { return }
        overlayPresentation = .expanded
        OverlayPanelController.shared.dockOverlay()
    }

    /// Records where the overlay ended up. Called by `OverlayPanelController` as its handoff
    /// animations finish, so menus and toolbars always match what's on screen.
    func setOverlayDock(_ dock: OverlayDock) {
        guard overlayDock != dock else { return }
        overlayDock = dock
    }

    func startMeeting() async {
        await startMeeting(continuing: nil)
    }

    /// Records more of an earlier meeting into the same session, e.g. after quitting Meetly mid-call.
    func continueMeeting(_ session: MeetingSession) async {
        await startMeeting(continuing: session)
    }

    private func startMeeting(continuing earlierSession: MeetingSession?) async {
        guard state == .idle, !isStartingMeeting, let modelContext else { return }

        isStartingMeeting = true
        autoStopSource = meetingDetector.activeMeeting?.source
        defer {
            isStartingMeeting = false
            // The share picker can stay open for a while, and that time isn't silence.
            noteRecordingActivity()
            reconcileDetection()
        }

        errorMessage = nil
        warningMessage = nil
        needsSystemAudioPicker = false
        isSystemAudioEnabled = false
        isMicrophoneMuted = false
        audioSourceRouter.reset()
        chatMessages = []
        liveCaptions = []
        micBleedFilter.reset()
        heldMicFinals = []
        transcribedSystemSpeechUptime = nil
        transcriptHistory = []
        activeQuestion = nil
        activeQuestionImages = []
        activeAnswer = nil
        overlayQAMessages = []
        overlayQAConversationID = UUID()
        partialMessageIDs.removeAll()
        lastFinalTranscriptAt.removeAll()
        pausedAt = nil
        accumulatedPausedDuration = 0

        guard aiService.isAvailable else {
            errorMessage = aiService.availabilityMessage
                ?? "Configure \(aiService.provider.label) in Settings before starting a meeting."
            return
        }

        guard await requestMicrophonePermission() else {
            errorMessage = "Microphone permission is required to start a meeting."
            return
        }

        // Whisper runs without this permission; prepare() requests it if a meeting falls back to Apple Speech.
        if AppSettings.transcriptionEngine == .appleSpeech {
            guard await AppleSpeechChannel.requestAuthorization() else {
                errorMessage = "Speech recognition permission is required to transcribe meetings."
                return
            }
        }

        let session: MeetingSession
        if let earlierSession {
            session = earlierSession
            beginContinuation(of: session)
        } else {
            session = MeetingSession()
            session.isArchived = false
            modelContext.insert(session)
            continuation = nil
        }
        try? modelContext.save()

        currentSession = session
        // Shifted by the gap so the timer picks up where the earlier recording left off.
        sessionStartedAt = session.startedAt.addingTimeInterval(session.continuationGapDuration ?? 0)
        state = .recording
        overlayPresentation = .expanded

        do {
            try await transcriptionService.prepare()
            try await transcriptionService.start()

            transcriptionService.onPartialResult = { [weak self] text, speaker in
                self?.handlePartialTranscript(text: text, speaker: speaker)
            }

            transcriptionService.onFinalResult = { [weak self] text, speaker in
                self?.handleFinalTranscript(text: text, speaker: speaker)
            }

            transcriptionService.onSystemChannelError = { [weak self] error in
                self?.handleSystemChannelError(error)
            }

            wireAudioRouting()

            if let warning = try await audioCaptureService.start() {
                warningMessage = warning
            }

            // Present the share picker before hiding the main window. SCContentSharingPicker
            // needs an active key window; orderOut + overlay orderFrontRegardless made the
            // picker fail/cancel silently when starting from the main window.
            if AppSettings.captureMeetingAudioByDefault {
                await enableSystemAudioAtStart()
            }

            // After the picker, which clears warningMessage on success.
            if let notice = transcriptionService.fallbackNotice {
                warningMessage = [warningMessage, notice].compactMap { $0 }.joined(separator: " ")
            }

            if overlayDock == .floating, OverlayPanelController.shared.isFloatingVisible {
                // Started from a popped-out prompt: meetings always start in the notch.
                MainWindowController.shared.hideMainWindow()
                OverlayPanelController.shared.dockOverlay()
            } else {
                overlayDock = .notch
                // The main window pours up into the notch, which opens into the overlay.
                OverlayPanelController.shared.showAbsorbingMainWindow()
            }
            OverlayPanelController.shared.updateForPresentation(.expanded)
        } catch {
            errorMessage = error.localizedDescription
            await stopMeeting(saveSummary: false)
        }
    }

    func enableSystemAudio() async {
        guard isMeetingActive, state == .recording else { return }
        noteRecordingActivity()
        isPickingSystemAudio = true
        defer {
            isPickingSystemAudio = false
            noteRecordingActivity()
        }
        await enableSystemAudioAtStart(forcePicker: true)
    }

    private func enableSystemAudioAtStart(forcePicker: Bool = false) async {
        prepareForContentSharingPicker()

        let warning: String?
        if forcePicker {
            warning = await audioCaptureService.enableSystemAudioViaPicker()
        } else {
            warning = await audioCaptureService.startSystemAudioIfPossible()
        }

        if let warning {
            warningMessage = warning
            needsSystemAudioPicker = true
            isSystemAudioEnabled = false
            audioSourceRouter.isSystemAudioEnabled = false
        } else {
            warningMessage = nil
            needsSystemAudioPicker = false
            isSystemAudioEnabled = true
            audioSourceRouter.isSystemAudioEnabled = true
        }
    }

    /// Ensures the app is active and has a key window so `SCContentSharingPicker` can present.
    private func prepareForContentSharingPicker() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if NSApp.keyWindow == nil {
            if MainWindowController.shared.isMainWindowVisible {
                MainWindowController.shared.showMainWindow()
            } else {
                OverlayPanelController.shared.presentKeyWindowForPicker()
            }
        }
    }

    private func wireAudioRouting() {
        let router = audioSourceRouter
        let transcription = transcriptionService

        router.onMicBuffer = { buffer in
            transcription.feedMicBuffer(buffer)
        }
        router.onSystemBuffer = { buffer in
            transcription.feedSystemBuffer(buffer)
        }

        // Single hop: capture thread → router → STT feed (no MainActor marshal for PCM).
        audioCaptureService.onMicBuffer = { buffer in
            router.processMicBuffer(buffer)
        }
        audioCaptureService.onSystemBuffer = { buffer in
            router.processSystemBuffer(buffer)
        }
    }

    private func handleSystemChannelError(_ error: Error) {
        warningMessage = "Meeting audio transcription failed: \(error.localizedDescription)"
        isSystemAudioEnabled = false
        audioSourceRouter.isSystemAudioEnabled = false
        needsSystemAudioPicker = true
    }

    func toggleMicrophoneMute() {
        guard isMeetingActive else { return }
        setMicrophoneMuted(!isMicrophoneMuted)
    }

    func setMicrophoneMuted(_ muted: Bool) {
        guard isMeetingActive else { return }
        noteRecordingActivity()
        isMicrophoneMuted = muted
        audioCaptureService.setMicrophoneMuted(muted)
        if muted {
            finalizePartialMessage(for: .me)
            removeCaption(for: .me)
        }
    }

    func pauseMeeting() async {
        guard state == .recording else { return }

        await audioCaptureService.pause()
        await transcriptionService.pause()
        releaseHeldMicFinals()
        finalizePartialMessages()
        liveCaptions = []
        pausedAt = Date()
        state = .paused
    }

    func resumeMeeting() async {
        guard state == .paused else { return }
        let pauseStartedAt = pausedAt

        do {
            try await transcriptionService.resume()
            prepareForContentSharingPicker()
            if let warning = try await audioCaptureService.resume() {
                warningMessage = warning
                if audioCaptureService.isSystemAudioRunning {
                    isSystemAudioEnabled = true
                    audioSourceRouter.isSystemAudioEnabled = true
                } else if isSystemAudioEnabled {
                    isSystemAudioEnabled = false
                    audioSourceRouter.isSystemAudioEnabled = false
                }
            }
            if let pauseStartedAt {
                accumulatedPausedDuration += Date().timeIntervalSince(pauseStartedAt)
            }
            pausedAt = nil
            noteRecordingActivity()
            state = .recording
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopMeeting(saveSummary: Bool = true) async {
        disarmAutoStop()
        // State stays .recording during the awaits below, so a poll mustn't see the recording as idle.
        noteRecordingActivity()
        suppressedSource = meetingDetector.activeMeeting?.source

        await audioCaptureService.stop()
        await transcriptionService.stop()
        releaseHeldMicFinals()

        overlayPresentation = .hidden
        // The overlay pours back out into the main window. Reads the dock before it's reset.
        OverlayPanelController.shared.hideIntoMainWindow()
        overlayDock = .notch

        if let currentSession {
            savePartialsIfTranscriptEmpty(in: currentSession)
        }

        if let currentSession, let continuation,
           currentSession.segments.count == continuation.segmentCountAtStart {
            // Nothing new was recorded: leave the earlier meeting, and its summary, untouched.
            currentSession.endedAt = continuation.previousEndedAt
            currentSession.continuationGapDuration = continuation.previousGapDuration
            try? modelContext?.save()
        } else if let currentSession, !hasTranscript(currentSession) {
            // No await until currentSession clears below, so a late transcript can't reach the deleted session.
            modelContext?.delete(currentSession)
            try? modelContext?.save()
        } else if let currentSession {
            currentSession.endedAt = .now
            try? modelContext?.save()

            if saveSummary {
                lastCompletedSessionID = currentSession.id
                state = .summarizing
                await generateSummary(for: currentSession)
            }
        }

        finalizePartialMessages()
        audioSourceRouter.reset()
        isMicrophoneMuted = false
        state = .idle
        currentSession = nil
        continuation = nil
        sessionStartedAt = nil
        pausedAt = nil
        accumulatedPausedDuration = 0
        reconcileDetection()
    }

    private func beginContinuation(of session: MeetingSession) {
        let segments = session.segments.sorted { $0.timestamp < $1.timestamp }
        continuation = Continuation(
            segmentCountAtStart: session.segments.count,
            previousEndedAt: session.endedAt,
            previousGapDuration: session.continuationGapDuration
        )

        // A meeting cut off by quitting has no end time; its last transcript is the closest thing.
        let recordingEndedAt = session.endedAt ?? segments.last?.timestamp ?? session.startedAt
        let gap = max(0, Date().timeIntervalSince(recordingEndedAt))
        session.continuationGapDuration = (session.continuationGapDuration ?? 0) + gap
        session.endedAt = nil
        restoreTranscript(from: segments)
    }

    /// Shows the earlier transcript in the overlay, which also puts it in the Q&A context.
    private func restoreTranscript(from segments: [TranscriptSegment]) {
        var lastTimestamp: [Speaker: Date] = [:]
        var lastSpeaker: Speaker?
        for segment in segments {
            let sender: ChatMessageSender = segment.speaker == .me ? .me : .other
            let merging = lastSpeaker == segment.speaker
                && lastTimestamp[segment.speaker].map {
                    segment.timestamp.timeIntervalSince($0) <= transcriptMergePauseThreshold
                } ?? false
            appendToTranscriptHistory(sender: sender, text: segment.text, merging: merging)
            if merging, let lastIndex = chatMessages.indices.last {
                chatMessages[lastIndex].text += " \(segment.text)"
            } else {
                chatMessages.append(
                    ChatMessage(
                        kind: .transcript,
                        sender: sender,
                        text: segment.text,
                        timestamp: segment.timestamp,
                        isPartial: false
                    )
                )
            }
            lastTimestamp[segment.speaker] = segment.timestamp
            lastSpeaker = segment.speaker
        }
    }

    private func hasTranscript(_ session: MeetingSession) -> Bool {
        !MeetingContextBuilder.transcriptText(for: session)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    /// Apple Speech can stop before finalizing a short utterance. Without this, a meeting
    /// whose only words were on screen as captions would be discarded as empty.
    private func savePartialsIfTranscriptEmpty(in session: MeetingSession) {
        guard !hasTranscript(session) else { return }
        for (speaker, messageID) in partialMessageIDs {
            guard let text = chatMessages.first(where: { $0.id == messageID })?.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            commitFinalTranscript(text: text, speaker: speaker, timestamp: .now)
        }
    }

    // MARK: - Meeting detection

    func dismissDetectedMeeting() {
        guard let detectedMeetingPrompt else { return }
        suppressedSource = detectedMeetingPrompt.source
        self.detectedMeetingPrompt = nil
        hideOverlayIfOpenedForPrompt()
    }

    /// Cancels the countdown. Auto-stop arms again if the call's mic comes back.
    func keepRecordingAfterCallEnded() {
        disarmAutoStop()
    }

    /// Brings prompts and auto-stop in line with the current call. Safe to run at any time.
    private func reconcileDetection() {
        #if DEBUG
        if isNotchDemoActive { return }
        #endif
        let activeMeeting = meetingDetector.activeMeeting

        if let suppressedSource, activeMeeting?.source != suppressedSource {
            self.suppressedSource = nil
        }

        switch state {
        case .idle:
            // Leave everything in place until startMeeting() has succeeded or failed.
            guard !isStartingMeeting else { return }
            disarmAutoStop()

            if let activeMeeting, AppSettings.detectMeetings, activeMeeting.source != suppressedSource {
                showDetectedMeetingPrompt(activeMeeting)
            } else {
                clearDetectedMeetingPrompt()
                hideOverlayIfOpenedForPrompt()
            }

        case .recording, .paused:
            clearDetectedMeetingPrompt()
            overlayShownForPrompt = false

            // stopMeeting() would strand the picker's caller if it ran while the share picker is open.
            guard !isStartingMeeting, !isPickingSystemAudio else { return }
            reconcileIdleStop(activeMeeting: activeMeeting)

            guard AppSettings.autoStopWhenCallEnds else {
                disarmAutoStop()
                return
            }

            if let activeMeeting {
                cancelAutoStopCountdown()
                autoStopSource = activeMeeting.source
            } else if autoStopSource != nil, autoStopTask == nil {
                beginAutoStopCountdown()
            }

        case .summarizing:
            clearDetectedMeetingPrompt()
            overlayShownForPrompt = false
            disarmAutoStop()
        }
    }

    private func showDetectedMeetingPrompt(_ meeting: DetectedMeeting) {
        if detectedMeetingPrompt != meeting {
            detectedMeetingPrompt = meeting
        }
        if overlayPresentation == .hidden {
            showOverlay()
            overlayShownForPrompt = true
        }
    }

    private func clearDetectedMeetingPrompt() {
        if detectedMeetingPrompt != nil {
            detectedMeetingPrompt = nil
        }
    }

    private func hideOverlayIfOpenedForPrompt() {
        guard overlayShownForPrompt else { return }
        overlayShownForPrompt = false
        hideOverlay()
    }

    private func beginAutoStopCountdown() {
        autoStopDeadline = Date().addingTimeInterval(autoStopCountdown)
        if overlayPresentation == .hidden {
            showOverlay()
        }

        autoStopTask = Task { [weak self, autoStopCountdown] in
            try? await Task.sleep(for: .seconds(autoStopCountdown))
            guard !Task.isCancelled, let self, self.isMeetingActive else { return }
            // Otherwise stopMeeting() would cancel this task, and with it the summary it generates.
            self.autoStopTask = nil
            await self.stopMeeting()
        }
    }

    private func cancelAutoStopCountdown() {
        autoStopTask?.cancel()
        autoStopTask = nil
        // This runs on every poll, and the overlay redraws on any write.
        if autoStopDeadline != nil {
            autoStopDeadline = nil
        }
    }

    private func disarmAutoStop() {
        cancelAutoStopCountdown()
        autoStopSource = nil
    }

    /// Cancels the countdown and restarts the silence timer.
    func keepRecordingDespiteSilence() {
        noteRecordingActivity()
    }

    private func noteRecordingActivity() {
        lastRecordingActivityAt = Date()
        cancelIdleStopCountdown()
    }

    /// Stops recordings left running. Paused recordings capture nothing, and a detected call
    /// has its own end signal and can be quiet for long stretches, so neither counts as idle.
    private func reconcileIdleStop(activeMeeting: DetectedMeeting?) {
        let limitMinutes = AppSettings.idleRecordingStopMinutes
        guard state == .recording,
              activeMeeting == nil,
              limitMinutes > 0,
              Date().timeIntervalSince(lastRecordingActivityAt) >= TimeInterval(limitMinutes) * 60 else {
            cancelIdleStopCountdown()
            return
        }
        if idleStopTask == nil {
            beginIdleStopCountdown()
        }
    }

    private func beginIdleStopCountdown() {
        idleStopDeadline = Date().addingTimeInterval(idleStopCountdown)
        if overlayPresentation == .hidden {
            showOverlay()
        }

        idleStopTask = Task { [weak self, idleStopCountdown] in
            try? await Task.sleep(for: .seconds(idleStopCountdown))
            guard !Task.isCancelled, let self, self.state == .recording else { return }
            // Otherwise stopMeeting() would cancel this task, and with it the summary it generates.
            self.idleStopTask = nil
            await self.stopMeeting()
        }
    }

    private func cancelIdleStopCountdown() {
        idleStopTask?.cancel()
        idleStopTask = nil
        // This runs on every poll and transcript, and the overlay redraws on any write.
        if idleStopDeadline != nil {
            idleStopDeadline = nil
        }
    }

    func dismissActiveAnswer() {
        overlayQAConversationID = UUID()
        overlayQAMessages = []
        activeAnswer = nil
        activeQuestion = nil
        activeQuestionImages = []
        isAwaitingAnswer = false
    }

    func askQuestion(_ text: String, images: [ChatImageAttachment] = []) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty, isMeetingActive else { return }
        noteRecordingActivity()

        let question = trimmed.isEmpty
            ? (images.count > 1
                ? "What can you tell me about these images?"
                : "What can you tell me about this image?")
            : trimmed

        let conversationID = overlayQAConversationID
        let conversationHistory = MeetingContextBuilder.conversationHistoryText(from: overlayQAMessages)
        let askedSession = currentSession
        let askedAt = Date.now
        let userMessage = ChatMessage(
            kind: .userQuestion,
            sender: .user,
            text: question,
            imageAttachments: images
        )
        chatMessages.append(userMessage)
        overlayQAMessages.append(userMessage)
        activeQuestion = question
        activeQuestionImages = images
        activeAnswer = nil

        if !images.isEmpty, aiService.imageAgent == nil {
            let message = AIService.imagesUnavailableMessage
            errorMessage = message
            appendOverlayAnswer(message, conversationID: conversationID)
            return
        }

        guard aiService.isAvailable || !images.isEmpty else {
            let message = aiService.availabilityMessage
                ?? "Configure \(aiService.provider.label) in Settings before asking questions."
            errorMessage = message
            appendOverlayAnswer(message, conversationID: conversationID)
            return
        }

        isAwaitingAnswer = true

        do {
            let transcript = transcriptContext()
            let answer = try await aiService.answerQuestion(
                transcript: transcript,
                question: question,
                images: images,
                conversationHistory: conversationHistory
            )
            // Saved even if the overlay chat was closed meanwhile, so it shows in the meeting's history.
            askedSession?.appendQAExchange(
                question: question,
                askedAt: askedAt,
                imageCount: images.count,
                answer: answer,
                context: modelContext
            )
            appendOverlayAnswer(answer, conversationID: conversationID)
        } catch {
            errorMessage = error.localizedDescription
            appendOverlayAnswer(
                "Sorry, I couldn't answer that: \(error.localizedDescription)",
                conversationID: conversationID
            )
        }

        if conversationID == overlayQAConversationID {
            isAwaitingAnswer = false
        }
    }

    /// Captures the display shared for meeting audio, opening the share picker first if there
    /// isn't one yet, or if the shared display isn't the screen the user is on. Failures are shown in the overlay chat and return nil.
    func captureScreenForQuestion() async -> ChatImageAttachment? {
        guard state == .recording, !isAwaitingAnswer, !isCapturingScreen else { return nil }
        isCapturingScreen = true
        defer { isCapturingScreen = false }
        noteRecordingActivity()

        // Read before any picker can move the pointer: the screen the user clicked from.
        let targetDisplayID = DisplayLocator.displayUnderPointer()

        if !audioCaptureService.canCaptureScreenshot {
            await enableSystemAudio()
            guard audioCaptureService.canCaptureScreenshot else {
                showScreenCaptureFailure("Choose a display in the share picker so Meets can capture your screen.")
                return nil
            }
        } else if let targetDisplayID,
                  let capturedDisplayID = audioCaptureService.capturedDisplayID,
                  capturedDisplayID != targetDisplayID {
            // The stream only covers the display picked for meeting audio, and another display
            // can't be captured without the picker's approval. Ask to switch it to this screen.
            isPickingSystemAudio = true
            prepareForContentSharingPicker()
            do {
                try await audioCaptureService.changeCapturedDisplayViaPicker()
            } catch {
                isPickingSystemAudio = false
                noteRecordingActivity()
                showScreenCaptureFailure(
                    "Meets can only capture the display shared for meeting audio. Choose this screen in the share picker to capture it."
                )
                return nil
            }
            isPickingSystemAudio = false
            noteRecordingActivity()
        }

        OverlayPanelController.shared.setHiddenForCapture(true)
        defer { OverlayPanelController.shared.setHiddenForCapture(false) }
        // Give the window server time to redraw without the overlay or the share picker.
        try? await Task.sleep(for: .milliseconds(150))

        do {
            let image = try await audioCaptureService.captureScreenshot()
            guard let attachment = ClipboardImageReader.attachment(from: image) else {
                showScreenCaptureFailure("Couldn't process the screenshot.")
                return nil
            }
            return attachment
        } catch {
            showScreenCaptureFailure("Couldn't capture your screen: \(error.localizedDescription)")
            return nil
        }
    }

    private func showScreenCaptureFailure(_ message: String) {
        let question = "Ask about my screen"
        let userMessage = ChatMessage(kind: .userQuestion, sender: .user, text: question)
        chatMessages.append(userMessage)
        overlayQAMessages.append(userMessage)
        activeQuestion = question
        activeQuestionImages = []
        activeAnswer = nil
        appendOverlayAnswer(message, conversationID: overlayQAConversationID)
    }

    private func appendOverlayAnswer(_ text: String, conversationID: UUID) {
        guard conversationID == overlayQAConversationID else { return }
        activeAnswer = text
        let message = ChatMessage(kind: .assistantAnswer, sender: .assistant, text: text)
        chatMessages.append(message)
        overlayQAMessages.append(message)
    }

    private func handlePartialTranscript(text: String, speaker: Speaker) {
        let sender: ChatMessageSender = speaker == .me ? .me : .other
        guard text != "…" else { return }
        noteRecordingActivity()

        if speaker == .other {
            micBleedFilter.recordSystemText(text, isFinal: false)
            discardMicBleed()
        } else if shouldHideMicPartial(text) {
            return
        }

        showCaption(text, for: sender)

        if let existingID = partialMessageIDs[speaker],
           let index = chatMessages.firstIndex(where: { $0.id == existingID }) {
            chatMessages[index].text = text
            chatMessages[index].isPartial = true
        } else {
            let message = ChatMessage(
                kind: .transcript,
                sender: sender,
                text: text,
                isPartial: true
            )
            partialMessageIDs[speaker] = message.id
            chatMessages.append(message)
        }
    }

    private func handleFinalTranscript(text: String, speaker: Speaker) {
        noteRecordingActivity()

        switch speaker {
        case .other:
            micBleedFilter.recordSystemText(text, isFinal: true)
            discardMicBleed()
            commitFinalTranscript(text: text, speaker: .other, timestamp: .now)
            markSystemTranscriptCaughtUpIfQuiet()
        case .me:
            if micBleedFilter.isBleed(text) {
                discardMicPartial()
            } else if isSystemTranscriptBehind {
                // The transcript this might duplicate hasn't been decoded yet. Wait for it
                // rather than show a "You" line that would then have to be taken back.
                discardMicPartial()
                holdMicFinal(text)
            } else {
                commitFinalTranscript(text: text, speaker: .me, timestamp: .now)
            }
        }
    }

    /// Mic captions wait while meeting audio is untranscribed, unless the user was already
    /// talking: speaker bleed starts with the meeting audio, never ahead of it.
    private func shouldHideMicPartial(_ text: String) -> Bool {
        if micBleedFilter.isBleed(text) {
            discardMicPartial()
            return true
        }
        return partialMessageIDs[.me] == nil && isSystemTranscriptBehind
    }

    private var isSystemTranscriptBehind: Bool {
        guard let lastSpeech = audioSourceRouter.lastSystemSpeechUptime,
              ProcessInfo.processInfo.systemUptime - lastSpeech <= micBleedOverlapWindow else {
            return false
        }
        guard let transcribedSystemSpeechUptime else { return true }
        return lastSpeech > transcribedSystemSpeechUptime
    }

    /// Once a final covers all the meeting audio heard so far, anything still held didn't match it,
    /// so it's the user's own speech.
    private func markSystemTranscriptCaughtUpIfQuiet() {
        guard let lastSpeech = audioSourceRouter.lastSystemSpeechUptime,
              ProcessInfo.processInfo.systemUptime - lastSpeech >= systemUtteranceEndSilence else {
            return
        }
        transcribedSystemSpeechUptime = lastSpeech
        releaseHeldMicFinals()
    }

    private func discardMicBleed() {
        heldMicFinals.removeAll { micBleedFilter.isBleed($0.text) }
        if let caption = liveCaptions.first(where: { $0.speaker == .me }),
           micBleedFilter.isBleed(caption.text) {
            discardMicPartial()
        }
    }

    private func discardMicPartial() {
        if let id = partialMessageIDs[.me] {
            chatMessages.removeAll { $0.id == id }
        }
        partialMessageIDs[.me] = nil
        removeCaption(for: .me)
    }

    private func holdMicFinal(_ text: String) {
        let held = HeldMicFinal(text: text, receivedAt: .now)
        heldMicFinals.append(held)
        Task { [weak self, micHoldDuration] in
            try? await Task.sleep(for: .seconds(micHoldDuration))
            self?.releaseExpiredMicFinals()
        }
    }

    private func releaseExpiredMicFinals() {
        let expired = heldMicFinals.filter { Date().timeIntervalSince($0.receivedAt) >= micHoldDuration }
        heldMicFinals.removeAll { Date().timeIntervalSince($0.receivedAt) >= micHoldDuration }
        expired.forEach { commitFinalTranscript(text: $0.text, speaker: .me, timestamp: $0.receivedAt) }
    }

    private func releaseHeldMicFinals() {
        let held = heldMicFinals
        heldMicFinals = []
        held.forEach { commitFinalTranscript(text: $0.text, speaker: .me, timestamp: $0.receivedAt) }
    }

    private func showCaption(_ text: String, for sender: ChatMessageSender) {
        if let index = liveCaptions.firstIndex(where: { $0.speaker == sender }) {
            liveCaptions[index].text = text
        } else {
            liveCaptions.append(LiveCaption(speaker: sender, text: text))
        }
    }

    private func removeCaption(for sender: ChatMessageSender) {
        liveCaptions.removeAll { $0.speaker == sender }
    }

    private func commitFinalTranscript(text: String, speaker: Speaker, timestamp: Date) {
        guard let currentSession, let modelContext else { return }

        let sender: ChatMessageSender = speaker == .me ? .me : .other
        let merging = shouldMergeTranscript(with: speaker)

        removeCaption(for: sender)
        appendToTranscriptHistory(sender: sender, text: text, merging: merging)
        mergeOrAppendFinalTranscript(text: text, sender: sender, merging: merging)

        partialMessageIDs[speaker] = nil
        lastFinalTranscriptAt[speaker] = .now

        let segment = TranscriptSegment(
            text: text,
            timestamp: timestamp,
            speaker: speaker,
            isFinal: true,
            session: currentSession
        )
        currentSession.segments.append(segment)
        modelContext.insert(segment)
        try? modelContext.save()
    }

    private func shouldMergeTranscript(with speaker: Speaker) -> Bool {
        guard let lastAt = lastFinalTranscriptAt[speaker] else { return false }
        return Date().timeIntervalSince(lastAt) <= transcriptMergePauseThreshold
    }

    private func appendToTranscriptHistory(sender: ChatMessageSender, text: String, merging: Bool) {
        let prefix = "[\(sender.label)] "
        if merging,
           let lastIndex = transcriptHistory.indices.last,
           transcriptHistory[lastIndex].hasPrefix(prefix) {
            transcriptHistory[lastIndex] += " \(text)"
        } else {
            transcriptHistory.append("\(prefix)\(text)")
        }
    }

    private func mergeOrAppendFinalTranscript(
        text: String,
        sender: ChatMessageSender,
        merging: Bool
    ) {
        if let partialIndex = lastPartialTranscriptIndex(for: sender) {
            if merging, let blockIndex = lastFinalizedTranscriptIndex(for: sender), blockIndex != partialIndex {
                chatMessages[blockIndex].text += " \(text)"
                chatMessages.remove(at: partialIndex)
            } else {
                chatMessages[partialIndex].text = text
                chatMessages[partialIndex].isPartial = false
            }
        } else if merging, let blockIndex = lastFinalizedTranscriptIndex(for: sender) {
            chatMessages[blockIndex].text += " \(text)"
        } else {
            chatMessages.append(
                ChatMessage(
                    kind: .transcript,
                    sender: sender,
                    text: text,
                    isPartial: false
                )
            )
        }
    }

    private func lastFinalizedTranscriptIndex(for sender: ChatMessageSender) -> Int? {
        chatMessages.lastIndex(where: { $0.kind == .transcript && !$0.isPartial && $0.sender == sender })
    }

    private func lastPartialTranscriptIndex(for sender: ChatMessageSender) -> Int? {
        chatMessages.lastIndex(where: { $0.kind == .transcript && $0.isPartial && $0.sender == sender })
    }

    private func finalizePartialMessages() {
        for index in chatMessages.indices where chatMessages[index].isPartial {
            chatMessages[index].isPartial = false
        }
        partialMessageIDs.removeAll()
    }

    private func finalizePartialMessage(for speaker: Speaker) {
        if let id = partialMessageIDs[speaker],
           let index = chatMessages.firstIndex(where: { $0.id == id }) {
            chatMessages[index].isPartial = false
        }
        partialMessageIDs[speaker] = nil
    }

    private func transcriptContext() -> String {
        var lines = chatMessages
            .filter { $0.kind == .transcript }
            .map { "[\($0.sender.label)] \($0.text)" }

        if lines.isEmpty {
            lines = transcriptHistory
        }

        return lines.joined(separator: "\n")
    }

    private func generateSummary(for session: MeetingSession) async {
        guard let modelContext else { return }

        let transcript = MeetingContextBuilder.transcriptText(for: session)

        guard !transcript.isEmpty else { return }

        do {
            let output = try await aiService.generateSummary(from: transcript)
            // A continued meeting already has one; its action items go with it via cascade.
            if let existing = session.summary {
                session.summary = nil
                modelContext.delete(existing)
            }
            let summary = MeetingSummary(
                summaryText: output.summary,
                keyPoints: output.keyPoints,
                session: session
            )
            summary.actionItems = output.actionItems.enumerated().map { index, text in
                ActionItem(text: text, sortOrder: index, summary: summary)
            }
            for item in summary.actionItems {
                modelContext.insert(item)
            }
            session.title = output.title
            session.summary = summary
            modelContext.insert(summary)
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }
}

#if DEBUG
// MARK: - Notch demo

extension SessionManager {
    /// Puts the overlay into a scripted state without audio, the store or the AI tools, so the
    /// notch can be recorded and tuned. Driven by `NotchDemoDriver`.
    func debugApplyNotchDemo(_ step: String) {
        switch step {
        case "idle", "detected":
            notchDemoTask?.cancel()
            resetNotchDemoTranscript()
            state = .idle
            sessionStartedAt = nil
            errorMessage = nil
            detectedMeetingPrompt = step == "detected"
                ? DetectedMeeting(source: .otherApp(bundleID: "us.zoom.xos"), name: "Zoom", isConfirmedMeeting: true)
                : nil
            showOverlay()
        case "recording":
            notchDemoTask?.cancel()
            resetNotchDemoTranscript()
            detectedMeetingPrompt = nil
            state = .recording
            sessionStartedAt = Date().addingTimeInterval(-754)
            if overlayPresentation == .hidden {
                showOverlay()
            }
        case "speak":
            playNotchDemoSpeech(
                "Thanks everyone for joining. Before we get into the roadmap, can we agree on what ships in the first release and who owns the migration?",
                speaker: .other
            )
        case "speakMe":
            playNotchDemoSpeech(
                "I think the migration should stay with the platform team, and we keep the release scoped to sign-in and billing.",
                speaker: .me
            )
        case "final":
            notchDemoTask?.cancel()
            finalizeNotchDemoCaptions()
        case "ask":
            activeQuestion = OverlayQuickPrompt.whatToSay
            activeQuestionImages = []
            activeAnswer = nil
            isAwaitingAnswer = true
        case "answer":
            isAwaitingAnswer = false
            activeAnswer = "Confirm the scope out loud: \"So release one is sign-in and billing, and platform owns the migration.\" "
                + "Then ask who signs off on the billing cutover date, since nobody has claimed it yet."
        case "dismiss":
            dismissActiveAnswer()
        case "countdown":
            autoStopDeadline = Date().addingTimeInterval(15)
        case "keep":
            autoStopDeadline = nil
            idleStopDeadline = nil
        case "pause":
            state = .paused
        case "resume":
            state = .recording
        case "mute":
            isMicrophoneMuted.toggle()
        case "mainWindow":
            MainWindowController.shared.showMainWindow()
        case "windowToNotch":
            // A meeting starting from the main window: it's sucked up into the notch.
            notchDemoTask?.cancel()
            resetNotchDemoTranscript()
            detectedMeetingPrompt = nil
            state = .recording
            sessionStartedAt = Date().addingTimeInterval(-754)
            overlayPresentation = .expanded
            overlayDock = .notch
            OverlayPanelController.shared.showAbsorbingMainWindow()
        case "notchToWindow":
            // The meeting stopping: the main window pours back out of the notch.
            notchDemoTask?.cancel()
            overlayPresentation = .hidden
            OverlayPanelController.shared.hideIntoMainWindow()
            overlayDock = .notch
            resetNotchDemoTranscript()
            state = .idle
            sessionStartedAt = nil
        case "popOut":
            popOutOverlay()
        case "dock":
            dockOverlay()
        case "picker":
            // The real share-picker path a meeting start takes with the main window hidden, so
            // the overlay (here, the notch) has to be the picker's key window. Records nothing.
            MainWindowController.shared.hideMainWindow()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPickingSystemAudio = true
                await self.enableSystemAudioAtStart(forcePicker: true)
                self.isPickingSystemAudio = false
            }
        case "show":
            showOverlay()
        case "hide":
            hideOverlay()
        case "stop":
            notchDemoTask?.cancel()
            hideOverlay()
            resetNotchDemoTranscript()
            state = .idle
            sessionStartedAt = nil
        default:
            break
        }
    }

    private func playNotchDemoSpeech(_ text: String, speaker: ChatMessageSender) {
        notchDemoTask?.cancel()
        finalizeNotchDemoCaptions()
        notchDemoTask = Task { @MainActor [weak self] in
            let words = text.split(separator: " ")
            for count in 1...words.count {
                try? await Task.sleep(for: .milliseconds(170))
                guard let self, !Task.isCancelled else { return }
                self.showCaption(words.prefix(count).joined(separator: " "), for: speaker)
            }
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled else { return }
            self.finalizeNotchDemoCaptions()
        }
    }

    private func finalizeNotchDemoCaptions() {
        for caption in liveCaptions {
            chatMessages.append(ChatMessage(kind: .transcript, sender: caption.speaker, text: caption.text))
        }
        liveCaptions = []
    }

    private func resetNotchDemoTranscript() {
        chatMessages = []
        liveCaptions = []
        activeQuestion = nil
        activeAnswer = nil
        isAwaitingAnswer = false
        autoStopDeadline = nil
        idleStopDeadline = nil
        isMicrophoneMuted = false
    }
}
#endif
