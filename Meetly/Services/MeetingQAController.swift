import Foundation
import SwiftData

@MainActor
@Observable
final class MeetingQAController {
    /// The in-flight question and any error replies, which aren't saved.
    private var pendingMessages: [ChatMessage] = []
    private(set) var isAwaitingAnswer = false
    private(set) var errorMessage: String?

    let session: MeetingSession

    private let aiService = AIService()

    init(session: MeetingSession) {
        self.session = session
    }

    /// Saved history (including questions asked in the overlay during the call), then unsaved messages.
    var messages: [ChatMessage] {
        session.sortedQAMessages.map(\.chatMessage) + pendingMessages
    }

    var isAvailable: Bool {
        aiService.isAvailable
    }

    var availabilityMessage: String? {
        aiService.availabilityMessage
    }

    var hasContent: Bool {
        MeetingContextBuilder.hasContent(for: session)
    }

    var canAsk: Bool {
        hasContent && isAvailable && !isAwaitingAnswer
    }

    var canClearHistory: Bool {
        !isAwaitingAnswer && !messages.isEmpty
    }

    /// Deletes the saved Ask AI history for this meeting, including questions asked in the overlay during the call.
    func clearHistory() {
        guard !isAwaitingAnswer else { return }
        let saved = session.qaMessages ?? []
        session.qaMessages = []
        if let context = session.modelContext {
            saved.forEach(context.delete)
            try? context.save()
        }
        pendingMessages.removeAll()
        errorMessage = nil
    }

    func ask(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAwaitingAnswer else { return }

        let history = messages
        let askedAt = Date.now
        let questionMessage = ChatMessage(kind: .userQuestion, sender: .user, text: trimmed, timestamp: askedAt)
        pendingMessages.append(questionMessage)
        errorMessage = nil

        guard hasContent else {
            let message = "This meeting has no transcript or summary to ask about yet."
            errorMessage = message
            pendingMessages.append(
                ChatMessage(kind: .assistantAnswer, sender: .assistant, text: message)
            )
            return
        }

        guard aiService.isAvailable else {
            let message = aiService.availabilityMessage
                ?? "Configure \(aiService.provider.label) in Settings before asking questions."
            errorMessage = message
            pendingMessages.append(
                ChatMessage(kind: .assistantAnswer, sender: .assistant, text: message)
            )
            return
        }

        isAwaitingAnswer = true
        defer { isAwaitingAnswer = false }

        do {
            let context = MeetingContextBuilder.context(for: session)
            let conversationHistory = MeetingContextBuilder.conversationHistoryText(
                from: history
            )
            let answer = try await aiService.answerQuestion(
                transcript: context,
                question: trimmed,
                conversationHistory: conversationHistory
            )
            pendingMessages.removeAll { $0.id == questionMessage.id }
            session.appendQAExchange(
                question: trimmed,
                askedAt: askedAt,
                answer: answer,
                context: session.modelContext
            )
        } catch {
            let message = "Sorry, I couldn't answer that: \(error.localizedDescription)"
            errorMessage = error.localizedDescription
            pendingMessages.append(
                ChatMessage(kind: .assistantAnswer, sender: .assistant, text: message)
            )
        }
    }
}
