import AppKit
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

private struct OverlayContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    func reportPreferredSize(maxHeight: CGFloat) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: OverlayPreferredSizeKey.self, value: proxy.size)
            }
        }
        .onPreferenceChange(OverlayPreferredSizeKey.self) { size in
            OverlayPanelController.shared.updatePreferredSize(size, maxHeight: maxHeight)
        }
    }
}

struct OverlayView: View {
    @Bindable var sessionManager: SessionManager
    @State private var questionText = ""
    @State private var pendingImages: [ChatImageAttachment] = []
    @State private var isShowingSettings = false
    @State private var isFollowingLive = true
    @State private var scrollDistanceFromBottom: CGFloat = 0
    @State private var measuredAnswerHeight: CGFloat = 0

    private static let liveSubtitleID = "live-subtitle"
    private static let activeAnswerID = "active-answer"
    private static let scrollBottomThreshold: CGFloat = 20

    private var hasQuestionContext: Bool {
        sessionManager.activeAnswer != nil
            || sessionManager.isAwaitingAnswer
            || sessionManager.activeQuestion != nil
    }

    /// Listening / thinking stay compact; answers grow from that baseline.
    private var scrollAreaHeight: CGFloat {
        guard sessionManager.activeAnswer != nil else {
            return OverlayGlassStyle.contentMaxHeightListening
        }
        return OverlayGlassStyle.answerContentHeight(measured: measuredAnswerHeight)
    }

    private var expandedMaxHeight: CGFloat {
        pendingImages.isEmpty
            ? OverlayGlassStyle.panelMaxHeight
            : OverlayGlassStyle.panelMaxHeightWithPendingImage
    }

    private var isFolded: Bool {
        sessionManager.overlayPresentation == .folded
    }

    var body: some View {
        Group {
            if sessionManager.isMeetingActive {
                meetingOverlay
            } else {
                idleOverlay
            }
        }
    }

    private var idleOverlay: some View {
        VStack(spacing: 0) {
            idleToolbar
            Divider().opacity(0.25)
            idleContent
        }
        .frame(width: OverlayGlassStyle.panelWidth)
        .overlayGlassPanel()
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .reportPreferredSize(maxHeight: OverlayGlassStyle.panelIdleMinHeight)
    }

    private var idleToolbar: some View {
        HStack(spacing: 10) {
            OverlayToolbarIconButton(systemImage: "eye.slash", help: "Hide overlay") {
                sessionManager.hideOverlay()
            }

            Spacer(minLength: 0)

            Text("Meetly")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            OverlaySettingsButton(sessionManager: sessionManager, isShowingSettings: $isShowingSettings)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var idleContent: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Ready to record")
                    .font(.headline)
                Text("Start when you're in your meeting.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let errorMessage = sessionManager.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await sessionManager.startMeeting() }
            } label: {
                Label("Start Recording", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var meetingOverlay: some View {
        VStack(spacing: 0) {
            OverlayMeetingToolbar(
                sessionManager: sessionManager,
                isShowingSettings: $isShowingSettings,
                isFolded: isFolded
            )

            VStack(spacing: 0) {
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
                    pendingImages: $pendingImages,
                    isDisabled: sessionManager.isAwaitingAnswer || !sessionManager.isMeetingActive
                ) { question, images in
                    Task { await sessionManager.askQuestion(question, images: images) }
                }
                .layoutPriority(1)
            }
            .opacity(isFolded ? 0 : 1)
            .frame(maxHeight: isFolded ? 0 : nil, alignment: .top)
            .clipped()
            .allowsHitTesting(!isFolded)
        }
        .frame(width: OverlayGlassStyle.panelWidth, alignment: .top)
        // Measure content height before filling the panel, so fold/expand sizing stays accurate.
        .reportPreferredSize(maxHeight: expandedMaxHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlayGlassPanel()
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .onAppear {
            OverlayPanelController.shared.setPreferredMaxHeight(expandedMaxHeight)
            OverlayPanelController.shared.setImagePasteHandler { [sessionManager] in
                guard !sessionManager.isAwaitingAnswer, sessionManager.isMeetingActive else { return }
                let attachments = ClipboardImageReader.readImages()
                guard !attachments.isEmpty else { return }
                withAnimation(OverlayGlassStyle.resizeAnimation) {
                    pendingImages.append(contentsOf: attachments)
                }
            }
        }
        .onChange(of: pendingImages.count) { _, _ in
            OverlayPanelController.shared.setPreferredMaxHeight(expandedMaxHeight)
        }
        .onChange(of: sessionManager.activeAnswer) { _, answer in
            if answer == nil {
                measuredAnswerHeight = 0
            }
        }
        .animation(OverlayGlassStyle.resizeAnimation, value: isFolded)
        .animation(OverlayGlassStyle.resizeAnimation, value: hasQuestionContext)
        .animation(OverlayGlassStyle.resizeAnimation, value: scrollAreaHeight)
        .animation(OverlayGlassStyle.resizeAnimation, value: pendingImages.map(\.id))
    }

    private func questionBanner(_ question: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if !sessionManager.activeQuestionImages.isEmpty {
                HStack(spacing: 6) {
                    ForEach(sessionManager.activeQuestionImages) { image in
                        ChatImageAttachmentPreview(attachment: image, style: .banner)
                    }
                }
            }

            Text(question)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
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
                    .id(Self.activeAnswerID)
                    .background {
                        // Size from the answer alone so live captions don't jitter the panel.
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: OverlayContentHeightKey.self,
                                value: proxy.size.height + 24 // content vertical padding
                            )
                        }
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
                    } else if sessionManager.state == .paused {
                        Text("Paused")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
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
            .onPreferenceChange(OverlayContentHeightKey.self) { height in
                updateMeasuredAnswerHeight(height)
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
            .onChange(of: sessionManager.activeAnswer) { _, answer in
                if answer != nil {
                    scrollToAnswer(proxy: proxy)
                } else {
                    resumeFollowingLive(proxy: proxy)
                }
            }
            .onChange(of: measuredAnswerHeight) { _, height in
                // Re-anchor after the panel grows so the answer stays in view.
                guard height > 0, sessionManager.activeAnswer != nil else { return }
                scrollToAnswer(proxy: proxy)
            }
            .overlay(alignment: .bottomTrailing) {
                if !isFollowingLive, sessionManager.activeAnswer == nil {
                    Button {
                        isFollowingLive = true
                        withAnimation(OverlayGlassStyle.resizeAnimation) {
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
        .frame(height: scrollAreaHeight)
        .layoutPriority(0)
    }

    private func updateMeasuredAnswerHeight(_ height: CGFloat) {
        guard sessionManager.activeAnswer != nil,
              height.isFinite,
              height > 0,
              abs(height - measuredAnswerHeight) > OverlayGlassStyle.resizeThreshold
        else { return }
        measuredAnswerHeight = height
    }

    private func scrollToAnswer(proxy: ScrollViewProxy) {
        // Wait a beat for the answer view to join the scroll hierarchy.
        DispatchQueue.main.async {
            withAnimation(OverlayGlassStyle.resizeAnimation) {
                proxy.scrollTo(Self.activeAnswerID, anchor: .top)
            }
        }
    }

    private func resumeFollowingLive(proxy: ScrollViewProxy) {
        isFollowingLive = true
        // Wait for transcript / live subtitle to re-enter the hierarchy after dismiss.
        DispatchQueue.main.async {
            withAnimation(OverlayGlassStyle.resizeAnimation) {
                proxy.scrollTo(Self.liveSubtitleID, anchor: .bottom)
            }
        }
    }

    private func scrollToLiveIfFollowing(proxy: ScrollViewProxy) {
        guard isFollowingLive, sessionManager.activeAnswer == nil else { return }
        withAnimation(OverlayGlassStyle.resizeAnimation) {
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
        .disabled(sessionManager.isAwaitingAnswer || !sessionManager.isMeetingActive)
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
