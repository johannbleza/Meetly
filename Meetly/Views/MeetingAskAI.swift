import SwiftUI

/// The Ask AI tab of the meeting detail view: the saved question/answer history for the meeting.
/// Questions are typed into `MeetingAskBar`, which floats at the bottom of every tab.
struct MeetingAskAITab: View {
    let qaController: MeetingQAController?
    var highlightQuery: String = ""
    let onAsk: (String) -> Void

    @State private var isConfirmingClear = false

    static let suggestions = [
        "Summarize the key decisions",
        "What are the next steps?",
        "What questions were left open?",
    ]

    var body: some View {
        Group {
            if let qaController, !qaController.messages.isEmpty || qaController.isAwaitingAnswer {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Spacer()
                        if qaController.canClearHistory {
                            ClearHistoryButton {
                                isConfirmingClear = true
                            }
                        }
                    }
                    ChatMessageListView(
                        messages: qaController.messages,
                        isAwaitingAnswer: qaController.isAwaitingAnswer,
                        style: .home,
                        scrollable: false,
                        highlightQuery: highlightQuery
                    )
                }
            } else {
                emptyState
            }
        }
        .alert("Clear Ask AI history?", isPresented: $isConfirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                qaController?.clearHistory()
            }
        } message: {
            Text("This deletes every question and answer for this meeting, including ones asked during the call. This cannot be undone.")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(emptyStateMessage)
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let qaController, qaController.canAsk {
                FlowingSuggestions(suggestions: Self.suggestions, onSelect: onAsk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyStateMessage: String {
        guard let qaController else { return "" }
        if !qaController.isAvailable {
            return qaController.availabilityMessage ?? "Configure AI in Settings to ask questions about this meeting."
        }
        if !qaController.hasContent {
            return "This meeting has no transcript or summary to ask about yet."
        }
        return "Ask anything about this meeting. Questions you asked during the call show up here too."
    }
}

/// The history icon that clears the meeting's Ask AI history.
private struct ClearHistoryButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isHovered ? AppTheme.danger : AppTheme.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovered ? AppTheme.bgHover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .onHover { isHovered = $0 }
        .help("Clear Ask AI history")
        .accessibilityLabel("Clear Ask AI history")
    }
}

private struct FlowingSuggestions: View {
    let suggestions: [String]
    let onSelect: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chips }
            VStack(alignment: .leading, spacing: 8) { chips }
        }
    }

    private var chips: some View {
        ForEach(suggestions, id: \.self) { suggestion in
            DetailPillButton(title: suggestion) {
                onSelect(suggestion)
            }
        }
    }
}

/// The floating "Resume" + "Ask about this meeting…" bar pinned to the bottom of the detail view.
struct MeetingAskBar: View {
    @Binding var text: String
    let isDisabled: Bool
    var onResume: (() -> Void)?
    let onSend: (String) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let onResume {
                Button(action: onResume) {
                    Label("Resume", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .medium))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(AppTheme.textPrimary)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(Capsule().fill(AppTheme.bgSidebar))
                        .overlay(Capsule().stroke(AppTheme.border, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .fixedSize()
                .help("Keep recording into this meeting. The summary is regenerated when you stop.")
            }

            HStack(spacing: 8) {
                TextField("Ask about this meeting…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(AppTheme.textPrimary)
                    .focused($isFocused)
                    .disabled(isDisabled)
                    .onSubmit(sendIfPossible)

                Button(action: sendIfPossible) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(canSend ? AppTheme.textPrimary : AppTheme.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(AppTheme.bgInput))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .disabled(!canSend)
                .help("Ask AI")
                .accessibilityLabel("Ask AI")
            }
            .padding(.leading, 18)
            .padding(.trailing, 5)
            .frame(height: 40)
            .background(Capsule().fill(AppTheme.bgSidebar))
            .overlay(
                Capsule().stroke(isFocused ? AppTheme.focusRing : AppTheme.border, lineWidth: 1)
            )
            .contentShape(Capsule())
            .onTapGesture { isFocused = true }
        }
        .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
    }

    private var canSend: Bool {
        !isDisabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendIfPossible() {
        guard canSend else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        onSend(trimmed)
    }
}

/// A small bordered capsule button used across the meeting detail view.
struct DetailPillButton: View {
    let title: String
    var systemImage: String?
    var isProminent = false
    /// A gray fill with no border.
    var isSubtle = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            DetailPillLabel(
                title: title,
                systemImage: systemImage,
                isProminent: isProminent,
                isSubtle: isSubtle,
                isHovered: isHovered
            )
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .onHover { isHovered = $0 }
    }
}

struct DetailPillLabel: View {
    let title: String
    var systemImage: String?
    var isProminent = false
    var isSubtle = false
    var isHovered = false
    var trailingChevron = false

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
            }
            Text(title)
            if trailingChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(isProminent ? AppTheme.onInk : AppTheme.textPrimary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isProminent || isSubtle ? Color.clear : AppTheme.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize()
    }

    private var fill: Color {
        if isProminent { return AppTheme.ink.opacity(isHovered ? 0.82 : 1) }
        if isSubtle { return isHovered ? AppTheme.bgHover : AppTheme.bgInput }
        return isHovered ? AppTheme.bgHover : AppTheme.bgSidebar
    }
}
