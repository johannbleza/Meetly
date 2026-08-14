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

@MainActor
@Observable
final class SessionManager {
    private(set) var state: MeetingState = .idle
    private(set) var currentSession: MeetingSession?
    private(set) var chatMessages: [ChatMessage] = []
    private(set) var liveSubtitle: String = ""
    private(set) var liveSubtitleSpeaker: ChatMessageSender?
    private(set) var isLiveSubtitlePartial = false
    private(set) var transcriptHistory: [String] = []
    private(set) var activeQuestion: String?
    private(set) var activeQuestionImages: [ChatImageAttachment] = []
    private(set) var activeAnswer: String?
    private(set) var isAwaitingAnswer = false
    private(set) var errorMessage: String?
    private(set) var warningMessage: String?
    private(set) var needsSystemAudioPicker = false
    private(set) var isSystemAudioEnabled = false
    private(set) var isMicrophoneMuted = false
    private(set) var sessionStartedAt: Date?
    private(set) var overlayPresentation: OverlayPresentation = .hidden
    private(set) var aiProviderSelection: AIProvider = AppSettings.aiProvider
    private(set) var lastCompletedSessionID: UUID?
    var requestedHomePanel: HomePanel?

    private let audioCaptureService = AudioCaptureService()
    private let audioSourceRouter = AudioSourceRouter()
    private let transcriptionService = LiveTranscriptionService()
    private let aiService = AIService()

    private var modelContext: ModelContext?
    private var partialMessageIDs: [Speaker: UUID] = [:]
    private var lastFinalTranscriptAt: [Speaker: Date] = [:]
    private var pausedAt: Date?
    private var accumulatedPausedDuration: TimeInterval = 0
    private var transcriptBleedFilter = TranscriptBleedFilter()
    private var recentMeFinals: [TrackedMeTranscript] = []

    private let transcriptMergePauseThreshold: TimeInterval = 3
    private let micBleedRetractWindow: TimeInterval = 8

    private struct TrackedMeTranscript {
        let text: String
        let date: Date
        let segment: TranscriptSegment
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

    func setReduceSpeakerBleed(_ enabled: Bool) {
        AppSettings.reduceSpeakerBleed = enabled
        audioSourceRouter.isEchoSuppressionEnabled = enabled
    }

    var aiAvailabilityMessage: String? {
        aiService.availabilityMessage
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func openSettings() {
        requestedHomePanel = .settings
        MainWindowController.shared.showMainWindow()
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
            toggleOverlay()
        case .summarizing:
            break
        }
    }

    func showOverlay() {
        overlayPresentation = .expanded
        OverlayPanelController.shared.show()
        OverlayPanelController.shared.updateForPresentation(.expanded)
    }

    func hideOverlay() {
        overlayPresentation = .hidden
        OverlayPanelController.shared.hide()
    }

    func foldOverlay() {
        guard isMeetingActive else { return }
        overlayPresentation = .folded
        OverlayPanelController.shared.updateForPresentation(.folded)
    }

    func expandOverlay() {
        guard isMeetingActive else { return }
        overlayPresentation = .expanded
        OverlayPanelController.shared.updateForPresentation(.expanded)
    }

    func startMeeting() async {
        guard state == .idle, let modelContext else { return }

        errorMessage = nil
        warningMessage = nil
        needsSystemAudioPicker = false
        isSystemAudioEnabled = false
        isMicrophoneMuted = false
        audioSourceRouter.reset()
        audioSourceRouter.isEchoSuppressionEnabled = AppSettings.reduceSpeakerBleed
        chatMessages = []
        liveSubtitle = ""
        liveSubtitleSpeaker = nil
        isLiveSubtitlePartial = false
        transcriptHistory = []
        activeQuestion = nil
        activeQuestionImages = []
        activeAnswer = nil
        partialMessageIDs.removeAll()
        lastFinalTranscriptAt.removeAll()
        transcriptBleedFilter.reset()
        recentMeFinals.removeAll()
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

        guard await AppleSpeechChannel.requestAuthorization() else {
            errorMessage = "Speech recognition permission is required to transcribe meetings."
            return
        }

        let session = MeetingSession()
        session.isArchived = false
        modelContext.insert(session)
        try? modelContext.save()

        currentSession = session
        sessionStartedAt = session.startedAt
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

            MainWindowController.shared.hideMainWindow()
            OverlayPanelController.shared.show()
            OverlayPanelController.shared.updateForPresentation(.expanded)
        } catch {
            errorMessage = error.localizedDescription
            await stopMeeting(saveSummary: false)
        }
    }

    func enableSystemAudio() async {
        guard isMeetingActive, state == .recording else { return }
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
                OverlayPanelController.shared.show()
                OverlayPanelController.shared.activateForInput()
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
        isMicrophoneMuted = muted
        audioCaptureService.setMicrophoneMuted(muted)
        if muted {
            finalizePartialMessage(for: .me)
            if liveSubtitleSpeaker == .me {
                clearLiveSubtitle()
            }
        }
    }

    func pauseMeeting() async {
        guard state == .recording else { return }

        await audioCaptureService.pause()
        await transcriptionService.pause()
        finalizePartialMessages()
        clearLiveSubtitle()
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
            state = .recording
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopMeeting(saveSummary: Bool = true) async {
        await audioCaptureService.stop()
        await transcriptionService.stop()

        overlayPresentation = .hidden
        OverlayPanelController.shared.hide()
        MainWindowController.shared.showMainWindow()

        if let currentSession {
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
        transcriptBleedFilter.reset()
        recentMeFinals.removeAll()
        isMicrophoneMuted = false
        state = .idle
        currentSession = nil
        sessionStartedAt = nil
        pausedAt = nil
        accumulatedPausedDuration = 0
    }

    func dismissActiveAnswer() {
        activeAnswer = nil
        activeQuestion = nil
        activeQuestionImages = []
    }

    func askQuestion(_ text: String, images: [ChatImageAttachment] = []) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty, isMeetingActive else { return }

        let question = trimmed.isEmpty
            ? (images.count > 1
                ? "What can you tell me about these images?"
                : "What can you tell me about this image?")
            : trimmed

        chatMessages.append(
            ChatMessage(
                kind: .userQuestion,
                sender: .user,
                text: question,
                imageAttachments: images
            )
        )
        activeQuestion = question
        activeQuestionImages = images
        activeAnswer = nil

        if !images.isEmpty, !GeminiRESTClient.isAvailable {
            let message = "Add your Gemini API key in Settings to ask about images."
            errorMessage = message
            activeAnswer = message
            chatMessages.append(
                ChatMessage(kind: .assistantAnswer, sender: .assistant, text: message)
            )
            return
        }

        guard aiService.isAvailable || !images.isEmpty else {
            let message = aiService.availabilityMessage
                ?? "Configure \(aiService.provider.label) in Settings before asking questions."
            errorMessage = message
            activeAnswer = message
            chatMessages.append(
                ChatMessage(kind: .assistantAnswer, sender: .assistant, text: message)
            )
            return
        }

        isAwaitingAnswer = true
        defer { isAwaitingAnswer = false }

        do {
            let transcript = transcriptContext()
            let answer = try await aiService.answerQuestion(
                transcript: transcript,
                question: question,
                images: images
            )
            activeAnswer = answer
            chatMessages.append(
                ChatMessage(kind: .assistantAnswer, sender: .assistant, text: answer)
            )
        } catch {
            let message = "Sorry, I couldn't answer that: \(error.localizedDescription)"
            errorMessage = error.localizedDescription
            activeAnswer = message
            chatMessages.append(
                ChatMessage(
                    kind: .assistantAnswer,
                    sender: .assistant,
                    text: message
                )
            )
        }
    }

    private func handlePartialTranscript(text: String, speaker: Speaker) {
        let sender: ChatMessageSender = speaker == .me ? .me : .other
        guard text != "…" else {
            isLiveSubtitlePartial = true
            return
        }

        if speaker == .other {
            transcriptBleedFilter.recordOtherPartial(text)
            if shouldFilterMicBleed, transcriptBleedFilter.looksLikeBleed(currentMicPartialText) {
                discardPartialMicTranscript()
            }
        } else if shouldFilterMicBleed, transcriptBleedFilter.looksLikeBleed(text) {
            discardPartialMicTranscript()
            return
        }

        liveSubtitle = text
        liveSubtitleSpeaker = sender
        isLiveSubtitlePartial = true

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
        guard let currentSession, let modelContext else { return }

        if speaker == .other {
            transcriptBleedFilter.recordOtherFinal(text)
            if shouldFilterMicBleed {
                retractMicBleed(matching: text)
                if transcriptBleedFilter.looksLikeBleed(currentMicPartialText) {
                    discardPartialMicTranscript()
                }
            }
        } else if shouldFilterMicBleed, transcriptBleedFilter.looksLikeBleed(text) {
            discardPartialMicTranscript()
            return
        }

        let sender: ChatMessageSender = speaker == .me ? .me : .other
        let merging = shouldMergeTranscript(with: speaker)

        liveSubtitle = text
        liveSubtitleSpeaker = sender
        isLiveSubtitlePartial = false

        appendToTranscriptHistory(sender: sender, text: text, merging: merging)
        mergeOrAppendFinalTranscript(text: text, sender: sender, merging: merging)

        partialMessageIDs[speaker] = nil
        lastFinalTranscriptAt[speaker] = .now

        let segment = TranscriptSegment(
            text: text,
            speaker: speaker,
            isFinal: true,
            session: currentSession
        )
        currentSession.segments.append(segment)
        modelContext.insert(segment)
        try? modelContext.save()

        if speaker == .me {
            recentMeFinals.append(TrackedMeTranscript(text: text, date: .now, segment: segment))
            pruneRecentMeFinals()
        }
    }

    private var shouldFilterMicBleed: Bool {
        AppSettings.reduceSpeakerBleed && isSystemAudioEnabled
    }

    private var currentMicPartialText: String {
        guard let id = partialMessageIDs[.me],
              let index = chatMessages.firstIndex(where: { $0.id == id }) else {
            return liveSubtitleSpeaker == .me ? liveSubtitle : ""
        }
        return chatMessages[index].text
    }

    private func discardPartialMicTranscript() {
        if let id = partialMessageIDs[.me],
           let index = chatMessages.firstIndex(where: { $0.id == id }) {
            chatMessages.remove(at: index)
        }
        partialMessageIDs[.me] = nil
        if liveSubtitleSpeaker == .me {
            clearLiveSubtitle()
        }
    }

    private func retractMicBleed(matching otherText: String) {
        pruneRecentMeFinals()
        let bleed = recentMeFinals.filter { TranscriptBleedFilter.textsMatch($0.text, otherText) }
        guard !bleed.isEmpty else { return }

        let bleedIDs = Set(bleed.map { $0.segment.persistentModelID })
        recentMeFinals.removeAll { bleedIDs.contains($0.segment.persistentModelID) }

        for item in bleed {
            removeMeTranscript(item)
        }
    }

    private func pruneRecentMeFinals() {
        let cutoff = Date().addingTimeInterval(-micBleedRetractWindow)
        recentMeFinals.removeAll { $0.date < cutoff }
    }

    private func removeMeTranscript(_ item: TrackedMeTranscript) {
        modelContext?.delete(item.segment)
        currentSession?.segments.removeAll { $0.persistentModelID == item.segment.persistentModelID }
        try? modelContext?.save()

        if let index = lastFinalizedTranscriptIndex(for: .me) {
            if chatMessages[index].text == item.text {
                chatMessages.remove(at: index)
            } else if chatMessages[index].text.hasSuffix(" \(item.text)") {
                chatMessages[index].text.removeLast(item.text.count + 1)
            }
        }

        let prefix = "[You] "
        if let lastIndex = transcriptHistory.indices.last,
           transcriptHistory[lastIndex].hasPrefix(prefix) {
            let body = String(transcriptHistory[lastIndex].dropFirst(prefix.count))
            if body == item.text {
                transcriptHistory.remove(at: lastIndex)
            } else if body.hasSuffix(" \(item.text)") {
                transcriptHistory[lastIndex] = prefix + String(body.dropLast(item.text.count + 1))
            }
        }

        if liveSubtitle == item.text, liveSubtitleSpeaker == .me {
            clearLiveSubtitle()
        }
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

    private func clearLiveSubtitle() {
        liveSubtitle = ""
        liveSubtitleSpeaker = nil
        isLiveSubtitlePartial = false
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

        if !liveSubtitle.isEmpty, liveSubtitle != "…" {
            let label = liveSubtitleSpeaker?.label ?? "Speaker"
            let liveLine = "[\(label)] \(liveSubtitle)"
            if lines.last != liveLine {
                lines.append(liveLine)
            }
        }

        return lines.joined(separator: "\n")
    }

    private func generateSummary(for session: MeetingSession) async {
        guard let modelContext else { return }

        let transcript = MeetingContextBuilder.transcriptText(for: session)

        guard !transcript.isEmpty else { return }

        do {
            let output = try await aiService.generateSummary(from: transcript)
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
