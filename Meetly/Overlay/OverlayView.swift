import SwiftUI

private struct OverlayPreferredSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.height > 0 {
            value = next
        }
    }
}

struct OverlayView: View {
    @Bindable var sessionManager: SessionManager
    @State private var questionText = ""
    @State private var isShowingSettings = false
    @State private var isFollowingLive = true
    @State private var scrollDistanceFromBottom: CGFloat = 0

    private static let liveSubtitleID = "live-subtitle"
    private static let scrollBottomThreshold: CGFloat = 20

    private var isExpanded: Bool {
        sessionManager.activeAnswer != nil
            || sessionManager.isAwaitingAnswer
            || sessionManager.activeQuestion != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.25)
            if let question = sessionManager.activeQuestion {
                questionBanner(question)
                Divider().opacity(0.15)
            }
            contentArea
            Divider().opacity(0.15)
            actionRow
            OverlayInputBar(
                text: $questionText,
                isDisabled: sessionManager.isAwaitingAnswer || sessionManager.state != .recording
            ) { question in
                Task { await sessionManager.askQuestion(question) }
            }
        }
        .frame(width: OverlayGlassStyle.panelWidth)
        .frame(
            minHeight: OverlayGlassStyle.panelMinHeight,
            maxHeight: OverlayGlassStyle.panelMaxHeight,
            alignment: .top
        )
        .overlayGlassPanel()
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: OverlayPreferredSizeKey.self, value: proxy.size)
            }
        }
        .onPreferenceChange(OverlayPreferredSizeKey.self) { size in
            OverlayPanelController.shared.updatePreferredSize(size)
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button("Hide", systemImage: "chevron.down") {
                sessionManager.toggleOverlay()
            }
            .controlSize(.small)
            .buttonStyle(.borderless)

            Spacer()

            HStack(spacing: 5) {
                Circle()
                    .fill(sessionManager.state == .recording ? .red : .secondary)
                    .frame(width: 6, height: 6)
                if let startedAt = sessionManager.sessionStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(elapsed(since: startedAt))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Button {
                isShowingSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .help("Settings")
            .popover(isPresented: $isShowingSettings, arrowEdge: .bottom) {
                OverlaySettingsView(sessionManager: sessionManager)
            }

            Button("Stop", systemImage: "stop.fill") {
                Task { await sessionManager.stopMeeting() }
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("Stop meeting")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func questionBanner(_ question: String) -> some View {
        HStack {
            Text(question)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: Capsule())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var finalizedTranscriptMessages: [ChatMessage] {
        sessionManager.chatMessages.filter { $0.kind == .transcript && !$0.isPartial }
    }

    private func contentStack(liveSubtitleID: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if sessionManager.activeAnswer == nil {
                if !finalizedTranscriptMessages.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(finalizedTranscriptMessages) { message in
                            Text("[\(message.sender.label)] \(message.text)")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.leading)
                                .id(message.id)
                        }
                    }
                } else if !sessionManager.transcriptHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(sessionManager.transcriptHistory.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.leading)
                                .id("transcript-history-\(index)")
                        }
                    }
                }
            }

            Group {
                if let answer = sessionManager.activeAnswer {
                    HStack(alignment: .top, spacing: 8) {
                        Text(answer)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineSpacing(2)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button {
                            sessionManager.dismissActiveAnswer()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Dismiss answer")
                    }
                }

                if !sessionManager.liveSubtitle.isEmpty, sessionManager.liveSubtitle != "…" {
                    VStack(alignment: .leading, spacing: 6) {
                        if sessionManager.activeAnswer != nil {
                            Divider().opacity(0.2)
                                .padding(.vertical, 4)
                        }
                        if let speaker = sessionManager.liveSubtitleSpeaker {
                            Text(speaker == .me ? "You" : "Other")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        Text(sessionManager.liveSubtitle)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary.opacity(sessionManager.isLiveSubtitlePartial ? 0.75 : 1))
                            .multilineTextAlignment(.leading)
                            .animation(.easeOut(duration: 0.15), value: sessionManager.liveSubtitle)
                    }
                    .id(liveSubtitleID)
                } else if sessionManager.activeAnswer == nil {
                    if sessionManager.isAwaitingAnswer {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .id(liveSubtitleID)
                    } else {
                        Text("Listening…")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .id(liveSubtitleID)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var contentArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                contentStack(liveSubtitleID: Self.liveSubtitleID)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
                    - geometry.contentOffset.y
                    - geometry.containerSize.height
            } action: { _, distanceFromBottom in
                scrollDistanceFromBottom = distanceFromBottom
            }
            .onScrollPhaseChange { _, newPhase in
                let isUserScrolling = newPhase == .interacting || newPhase == .decelerating
                let isAtBottom = scrollDistanceFromBottom <= Self.scrollBottomThreshold
                if isUserScrolling, !isAtBottom {
                    isFollowingLive = false
                }
            }
            .onChange(of: sessionManager.liveSubtitle) { _, _ in
                scrollToLiveIfFollowing(proxy: proxy)
            }
            .onChange(of: finalizedTranscriptMessages.count) { _, _ in
                scrollToLiveIfFollowing(proxy: proxy)
            }
            .onChange(of: sessionManager.activeAnswer) { _, _ in
                scrollToLiveIfFollowing(proxy: proxy)
            }
            .overlay(alignment: .bottomTrailing) {
                if !isFollowingLive {
                    Button {
                        isFollowingLive = true
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(Self.liveSubtitleID, anchor: .bottom)
                        }
                    } label: {
                        Label("Jump to live", systemImage: "arrow.down")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(8)
                }
            }
        }
        .frame(
            minHeight: isExpanded ? 120 : 100,
            maxHeight: isExpanded ? nil : OverlayGlassStyle.contentMaxHeightCompact
        )
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func scrollToLiveIfFollowing(proxy: ScrollViewProxy) {
        guard isFollowingLive else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.liveSubtitleID, anchor: .bottom)
        }
    }

    private var actionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                actionButton("Assist", icon: "sparkles") {
                    Task { await sessionManager.askQuestion("How can I assist in this meeting right now?") }
                }
                actionButton("What to say", icon: "text.quote") {
                    Task { await sessionManager.askQuestion("What should I say next based on this conversation?") }
                }
                actionButton("Follow-ups", icon: "bubble.left") {
                    Task { await sessionManager.askQuestion("Suggest 2-3 good follow-up questions I could ask.") }
                }
                actionButton("Recap", icon: "arrow.clockwise") {
                    Task { await sessionManager.askQuestion("Give me a brief recap of what's been discussed so far.") }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .padding(.top, 4)
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption)
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
        .disabled(sessionManager.isAwaitingAnswer || sessionManager.state != .recording)
    }

    private func elapsed(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

#Preview {
    OverlayView(sessionManager: SessionManager())
        .padding(40)
        .background {
            Image(systemName: "photo")
                .resizable()
                .scaledToFill()
                .opacity(0.3)
        }
}
