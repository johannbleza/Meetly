import SwiftUI

enum ChatMessageListStyle {
    case overlay
    case home
}

struct ChatMessageListView: View {
    let messages: [ChatMessage]
    let isAwaitingAnswer: Bool
    var style: ChatMessageListStyle = .overlay
    var scrollable: Bool = true

    var body: some View {
        if scrollable {
            ScrollViewReader { proxy in
                ScrollView {
                    messageStack
                }
                .onChange(of: messages.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: isAwaitingAnswer) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
            }
        } else {
            messageStack
        }
    }

    private var messageStack: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(messages) { message in
                ChatBubbleView(message: message, style: style)
                    .id(message.id)
            }

            if isAwaitingAnswer {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("AI is thinking...")
                        .font(.appCaption)
                        .foregroundStyle(style == .home ? AppTheme.textSecondary : .secondary)
                }
                .padding(.horizontal, 4)
                .id("typing-indicator")
            }
        }
        .padding(.horizontal, style == .home ? 0 : 12)
        .padding(.vertical, style == .home ? 0 : 8)
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
    let style: ChatMessageListStyle

    private var isRightAligned: Bool {
        message.sender == .me || message.sender == .user
    }

    var body: some View {
        HStack {
            if isRightAligned { Spacer(minLength: 24) }

            VStack(alignment: isRightAligned ? .trailing : .leading, spacing: 4) {
                Text(message.sender.label)
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(labelColor)

                Text(message.text)
                    .font(.appBody)
                    .foregroundStyle(textColor)
                    .multilineTextAlignment(isRightAligned ? .trailing : .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(bubbleColor)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if !isRightAligned { Spacer(minLength: 24) }
        }
    }

    private var textColor: Color {
        if message.isPartial {
            return style == .home ? AppTheme.textSecondary : .secondary
        }
        return style == .home ? AppTheme.textPrimary : .primary
    }

    private var labelColor: Color {
        switch (message.sender, style) {
        case (.me, _), (.user, _):
            return style == .home ? AppTheme.accent : .blue
        case (.other, .home):
            return AppTheme.textSecondary
        case (.other, .overlay):
            return .secondary
        case (.assistant, .home):
            return AppTheme.accent.opacity(0.85)
        case (.assistant, .overlay):
            return .purple
        }
    }

    private var bubbleColor: Color {
        switch (message.sender, style) {
        case (.me, .home), (.user, .home):
            return AppTheme.accent.opacity(0.15)
        case (.me, .overlay), (.user, .overlay):
            return Color.blue.opacity(0.15)
        case (.other, .home):
            return AppTheme.bgInput
        case (.other, .overlay):
            return Color.primary.opacity(0.06)
        case (.assistant, .home):
            return AppTheme.bgInput.opacity(0.85)
        case (.assistant, .overlay):
            return Color.purple.opacity(0.12)
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
