import Foundation
import SwiftData

/// A saved question or answer from asking AI about a meeting, during the call or afterwards.
@Model
final class QAMessage {
    var id: UUID
    var text: String
    var timestamp: Date
    /// "question" or "answer".
    var roleRaw: String
    /// Images attached to the question. Only the count is kept, not the image data.
    var imageCount: Int?
    var session: MeetingSession?

    var isQuestion: Bool {
        roleRaw == Self.questionRole
    }

    init(
        id: UUID = UUID(),
        text: String,
        timestamp: Date = .now,
        isQuestion: Bool,
        imageCount: Int? = nil,
        session: MeetingSession? = nil
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.roleRaw = isQuestion ? Self.questionRole : Self.answerRole
        self.imageCount = imageCount
        self.session = session
    }

    private static let questionRole = "question"
    private static let answerRole = "answer"

    var chatMessage: ChatMessage {
        let count = imageCount ?? 0
        let displayText = isQuestion && count > 0
            ? "\(text)\n(\(count) image\(count == 1 ? "" : "s") attached)"
            : text
        return ChatMessage(
            id: id,
            kind: isQuestion ? .userQuestion : .assistantAnswer,
            sender: isQuestion ? .user : .assistant,
            text: displayText,
            timestamp: timestamp
        )
    }
}

extension MeetingSession {
    /// Saves a question and its answer to the meeting's Ask AI history.
    func appendQAExchange(
        question: String,
        askedAt: Date,
        imageCount: Int = 0,
        answer: String,
        context: ModelContext?
    ) {
        // The meeting may have been deleted while the answer was loading (stopped with no transcript).
        guard !isDeleted, modelContext != nil else { return }
        let questionMessage = QAMessage(
            text: question,
            timestamp: askedAt,
            isQuestion: true,
            imageCount: imageCount > 0 ? imageCount : nil
        )
        // Keep the answer strictly after the question so sorting by time keeps them paired.
        let answerMessage = QAMessage(
            text: answer,
            timestamp: max(.now, askedAt.addingTimeInterval(0.001)),
            isQuestion: false
        )
        if qaMessages == nil { qaMessages = [] }
        qaMessages?.append(questionMessage)
        qaMessages?.append(answerMessage)
        try? context?.save()
    }
}
