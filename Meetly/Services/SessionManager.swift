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
    private(set) var activeAnswer: String?
    private(set) var isAwaitingAnswer = false
    private(set) var errorMessage: String?
    private(set) var warningMessage: String?
    private(set) var needsSystemAudioPicker = false
    private(set) var isSystemAudioEnabled = false
    private(set) var sessionStartedAt: Date?
    private(set) var overlayPresentation: OverlayPresentation = .hidden
    private(set) var aiProviderSelection: AIProvider = AppSettings.aiProvider
    private(set) var lastCompletedSessionID: UUID?
    var requestedHomePanel: HomePanel?

    private let audioCaptureService = AudioCaptureService()
    private let transcriptionService = LiveTranscriptionService()
    private let aiService = AIService()

    private var modelContext: ModelContext?
    private var partialMessageIDs: [Speaker: UUID] = [:]
    private var lastFinalTranscriptAt: [Speaker: Date] = [:]
    private var pausedAt: Date?
    private var accumulatedPausedDuration: TimeInterval = 0

    private let transcriptMergePauseThreshold: TimeInterval = 3

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
        case .idle:
            Task { await startMeeting() }
        case .recording, .paused:
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
        chatMessages = []
        liveSubtitle = ""
        liveSubtitleSpeaker = nil
        isLiveSubtitlePartial = false
        transcriptHistory = []
        activeQuestion = nil
        activeAnswer = nil
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
        MainWindowController.shared.hideMainWindow()
        OverlayPanelController.shared.show()
        OverlayPanelController.shared.updateForPresentation(.expanded)

        do {
            try await transcriptionService.prepare()
            try await transcriptionService.start()

            transcriptionService.onPartialResult = { [weak self] text, speaker in
                Task { @MainActor in
                    self?.handlePartialTranscript(text: text, speaker: speaker)
                }
            }

            transcriptionService.onFinalResult = { [weak self] text, speaker in
                Task { @MainActor in
                    self?.handleFinalTranscript(text: text, speaker: speaker)
                }
            }

            audioCaptureService.onMicBuffer = { [weak self] buffer in
                Task { @MainActor in
                    self?.transcriptionService.feedMicBuffer(buffer)
                }
            }

            audioCaptureService.onSystemBuffer = { [weak self] buffer in
                Task { @MainActor in
                    self?.transcriptionService.feedSystemBuffer(buffer)
                }
            }

            if let warning = try await audioCaptureService.start() {
                warningMessage = warning
            }
        } catch {
            errorMessage = error.localizedDescription
            await stopMeeting(saveSummary: false)
        }
    }

    func enableSystemAudio() async {
        guard isMeetingActive, state == .recording else { return }

        if let warning = await audioCaptureService.enableSystemAudioViaPicker() {
            warningMessage = warning
            needsSystemAudioPicker = true
            isSystemAudioEnabled = false
        } else {
            warningMessage = nil
            needsSystemAudioPicker = false
            isSystemAudioEnabled = true
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
            if let warning = try await audioCaptureService.resume() {
                warningMessage = warning
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
        state = .idle
        currentSession = nil
        sessionStartedAt = nil
        pausedAt = nil
        accumulatedPausedDuration = 0
    }

    func dismissActiveAnswer() {
        activeAnswer = nil
        activeQuestion = nil
    }

    func askQuestion(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isMeetingActive else { return }

        chatMessages.append(
            ChatMessage(kind: .userQuestion, sender: .user, text: trimmed)
        )
        activeQuestion = trimmed
        activeAnswer = nil

        guard aiService.isAvailable else {
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
            let answer = try await aiService.answerQuestion(transcript: transcript, question: trimmed)
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
