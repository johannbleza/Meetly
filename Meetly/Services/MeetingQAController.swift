import Foundation

@MainActor
@Observable
final class MeetingQAController {
    private(set) var messages: [ChatMessage] = []
    private(set) var isAwaitingAnswer = false
    private(set) var errorMessage: String?

    let session: MeetingSession

    private let aiService = AIService()

    init(session: MeetingSession) {
        self.session = session
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

    func ask(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAwaitingAnswer else { return }

        messages.append(
            ChatMessage(kind: .userQuestion, sender: .user, text: trimmed)
        )
        errorMessage = nil

        guard hasContent else {
            let message = "This meeting has no transcript or summary to ask about yet."
            errorMessage = message
            messages.append(
                ChatMessage(kind: .assistantAnswer, sender: .assistant, text: message)
            )
            return
        }

        guard aiService.isAvailable else {
            let message = aiService.availabilityMessage
                ?? "Configure \(aiService.provider.label) in Settings before asking questions."
            errorMessage = message
            messages.append(
                ChatMessage(kind: .assistantAnswer, sender: .assistant, text: message)
            )
            return
        }

        isAwaitingAnswer = true
        defer { isAwaitingAnswer = false }

        do {
            let context = MeetingContextBuilder.context(for: session)
            let answer = try await aiService.answerQuestion(transcript: context, question: trimmed)
            messages.append(
                ChatMessage(kind: .assistantAnswer, sender: .assistant, text: answer)
            )
        } catch {
            let message = "Sorry, I couldn't answer that: \(error.localizedDescription)"
            errorMessage = error.localizedDescription
            messages.append(
                ChatMessage(kind: .assistantAnswer, sender: .assistant, text: message)
            )
        }
    }
}
