import Foundation

enum ChatMessageKind: Equatable {
    case transcript
    case userQuestion
    case assistantAnswer
}

enum ChatMessageSender: Equatable {
    case me
    case other
    case user
    case assistant

    var label: String {
        switch self {
        case .me: "You"
        case .other: "Other"
        case .user: "You"
        case .assistant: "AI"
        }
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let kind: ChatMessageKind
    let sender: ChatMessageSender
    var text: String
    let timestamp: Date
    var isPartial: Bool

    init(
        id: UUID = UUID(),
        kind: ChatMessageKind,
        sender: ChatMessageSender,
        text: String,
        timestamp: Date = .now,
        isPartial: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.sender = sender
        self.text = text
        self.timestamp = timestamp
        self.isPartial = isPartial
    }
}
