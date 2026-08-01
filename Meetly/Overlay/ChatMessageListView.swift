import SwiftUI

struct ChatMessageListView: View {
    let messages: [ChatMessage]
    let isAwaitingAnswer: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(messages) { message in
                        ChatBubbleView(message: message)
                            .id(message.id)
                    }

                    if isAwaitingAnswer {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("AI is thinking...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                        .id("typing-indicator")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: isAwaitingAnswer) { _, _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if isAwaitingAnswer {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("typing-indicator", anchor: .bottom)
            }
        } else if let lastID = messages.last?.id {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }
}

private struct ChatBubbleView: View {
    let message: ChatMessage

    private var isRightAligned: Bool {
        message.sender == .me || message.sender == .user
    }

    var body: some View {
        HStack {
            if isRightAligned { Spacer(minLength: 24) }

            VStack(alignment: isRightAligned ? .trailing : .leading, spacing: 4) {
                Text(message.sender.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(labelColor)

                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(message.isPartial ? .secondary : .primary)
                    .multilineTextAlignment(isRightAligned ? .trailing : .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(bubbleColor)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if !isRightAligned { Spacer(minLength: 24) }
        }
    }

    private var labelColor: Color {
        switch message.sender {
        case .me, .user: .blue
        case .other: .secondary
        case .assistant: .purple
        }
    }

    private var bubbleColor: Color {
        switch message.sender {
        case .me, .user: Color.blue.opacity(0.15)
        case .other: Color.primary.opacity(0.06)
        case .assistant: Color.purple.opacity(0.12)
        }
    }
}

#Preview {
    ChatMessageListView(
        messages: [
            ChatMessage(kind: .transcript, sender: .other, text: "Can you share the timeline?"),
            ChatMessage(kind: .transcript, sender: .me, text: "I'll have it by Friday."),
            ChatMessage(kind: .userQuestion, sender: .user, text: "What did they ask?"),
            ChatMessage(kind: .assistantAnswer, sender: .assistant, text: "They asked about the timeline."),
        ],
        isAwaitingAnswer: false
    )
    .frame(width: 340, height: 360)
}
