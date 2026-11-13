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
    var highlightQuery: String = ""

    var body: some View {
        if scrollable {
            ScrollViewReader { proxy in
                ScrollView {
                    messageStack
                }
                .onChange(of: messages.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                // A saved answer replaces the pending question, so the count alone can miss it.
                .onChange(of: messages.last?.id) { _, _ in
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
                ChatBubbleView(message: message, style: style, highlightQuery: highlightQuery)
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

            Color.clear
                .frame(height: 1)
                .id(Self.bottomAnchorID)
        }
        .padding(.horizontal, style == .home ? 0 : 12)
        .padding(.vertical, style == .home ? 0 : 8)
    }

    private static let bottomAnchorID = "chat-bottom"

    private func scrollToBottom(proxy: ScrollViewProxy) {
        // Scrolling in the same update lands short of a long new answer, because its bubble
        // hasn't been measured yet. Wait for layout, then settle once more after it has.
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
    }
}

private struct ChatBubbleView: View {
    let message: ChatMessage
    let style: ChatMessageListStyle
    var highlightQuery: String = ""

    private var showsLabel: Bool {
        message.sender == .me || message.sender == .other
    }

    private var isRightAligned: Bool {
        message.sender == .me || message.sender == .user
    }

    var body: some View {
        HStack {
            if isRightAligned { Spacer(minLength: 24) }

            VStack(alignment: isRightAligned ? .trailing : .leading, spacing: 4) {
                // Questions and answers are told apart by side and color; only transcript
                // lines (You / Speaker) need a name.
                if showsLabel {
                    Text(message.sender.label)
                        .font(.appCaption.weight(.semibold))
                        .foregroundStyle(labelColor)
                }

                HighlightedText(text: message.text, query: highlightQuery, foreground: textColor)
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
        case (.me, _):
            return style == .home ? AppTheme.accent : .blue
        case (.other, .home):
            return AppTheme.textSecondary
        case (.other, .overlay):
            return .secondary
        case (.user, _), (.assistant, _):
            return .clear
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
