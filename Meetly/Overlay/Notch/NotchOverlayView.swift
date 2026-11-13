import SwiftUI

/// What the notch is showing, ordered from smallest to largest so a change can tell whether
/// the notch is growing (bouncy spring) or shrinking (calmer spring).
enum NotchContent: Int, Comparable {
    case retracted
    case receptive
    case compact
    case captions
    case idlePrompt
    case expanded
    case answer

    static func < (lhs: NotchContent, rhs: NotchContent) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The overlay drawn as a shape growing out of the notch. Lives in `NotchPanelController`'s
/// fixed-size canvas; only the shape and its content change size.
struct NotchOverlayView: View {
    var sessionManager: SessionManager
    let model: NotchModel
    let controller: NotchPanelController

    @State private var previousContent: NotchContent = .retracted
    /// Keeps captions up for a moment after speech stops, so pauses between sentences
    /// don't collapse the notch.
    @State private var isLingering = false
    @State private var lingerToken = 0
    @State private var draftQuestion = ""
    /// Height of the caption stack in the hovered notch: the transcript history starts at
    /// exactly this height, so dragging it open grows from where it is instead of jumping.
    @State private var captionStackHeight: CGFloat = 0
    @State private var splash: CGFloat = 0
    @FocusState private var isQuestionFieldFocused: Bool

    private let lingerDuration: Duration = .seconds(4)

    private var metrics: NotchMetrics {
        model.metrics
    }

    private var hasCountdown: Bool {
        sessionManager.isMeetingActive
            && (sessionManager.autoStopDeadline != nil || sessionManager.idleStopDeadline != nil)
    }

    var content: NotchContent {
        switch model.phase {
        case .receptive:
            return .receptive
        case .detached:
            return .retracted
        case .docked:
            break
        }
        guard model.isPresented else { return .retracted }
        guard sessionManager.isMeetingActive else { return .idlePrompt }
        if sessionManager.activeAnswer != nil || sessionManager.isAwaitingAnswer {
            return .answer
        }
        if model.isHovering || model.isComposing || model.isShowingSettings {
            return .expanded
        }
        if !sessionManager.liveCaptions.isEmpty || isLingering || hasCountdown {
            return .captions
        }
        return .compact
    }

    var body: some View {
        let content = self.content
        let pull = model.pull
        let shape = NotchShape(
            flare: flare(for: content),
            bottomRadius: bottomRadius(for: content),
            stretch: pull.height,
            sway: pull.width,
            squeeze: min(pull.height, 0) * 0.8 + splash
        )

        VStack(spacing: 0) {
            if showsTopBar(content) {
                topBar(content)
            }
            // Outgoing and incoming content overlap instead of stacking, so the shape heads
            // straight for its new height rather than growing by both first.
            ZStack(alignment: .top) {
                bodyContent(content)
            }
        }
        .frame(width: bodyWidth(for: content), alignment: .top)
        .frame(height: fixedHeight(for: content), alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        // Pulling stretches a plain black drop: the content fades out instead of being
        // dragged into the narrowing shape and clipped.
        .opacity(1 - OverlayPhysics.smoothstep(2, 12, abs(pull.height) + abs(pull.width) * 0.5))
        .clipShape(shape)
        // Pull the notch from anywhere on it, text included; buttons still take their own clicks.
        .contentShape(shape)
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { value in
                    controller.pullChanged(translation: value.translation)
                }
                .onEnded { _ in
                    controller.pullEnded()
                }
        )
        .background {
            shape.fill(.black)
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            model.shapeFrame = frame
        }
        // A virtual notch has no hardware to hide behind, so it fades when it retracts.
        .opacity(metrics.hasHardwareNotch || content != .retracted ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The drop and bridges melt into the notch from behind it.
        .background {
            NotchLiquidLayer(model: model)
        }
        .animation(animation(to: content, from: previousContent), value: content)
        .onChange(of: content, initial: true) { oldContent, newContent in
            if newContent > oldContent, newContent > .receptive, model.pull == .zero {
                playSplash()
            }
            previousContent = newContent
            let grows = newContent == .expanded || newContent == .answer
            model.canGrowHistory = grows
            model.isShowingAnswer = newContent == .answer
            // Leaving the answer for the small notch: the next hover opens at its normal size.
            if !grows, model.historyHeight != 0 {
                model.historyHeight = 0
            }
        }
        .onChange(of: sessionManager.liveCaptions.isEmpty) { _, isEmpty in
            if isEmpty, sessionManager.isMeetingActive { startLingering() }
        }
        .onChange(of: finalizedTranscript.last?.id) { _, lastID in
            // Nil when a meeting starts and the transcript is cleared: nothing to linger on.
            if lastID != nil { startLingering() }
        }
        .task(id: lingerToken) {
            guard lingerToken > 0 else { return }
            try? await Task.sleep(for: lingerDuration)
            guard !Task.isCancelled else { return }
            isLingering = false
        }
    }

    // MARK: - Geometry per state

    private func bodyWidth(for content: NotchContent) -> CGFloat {
        let notch = metrics.notchSize.width
        let width: CGFloat = switch content {
        case .retracted: notch - 6
        case .receptive: notch - 6 + 80 * model.reach
        case .compact: notch + 2 * 62
        case .captions: max(notch + 2 * 138, 460)
        case .idlePrompt: max(notch + 2 * 130, 460)
        case .expanded: max(notch + 2 * 168, 520)
        case .answer: max(notch + 2 * 178, 540)
        }
        return width + 40 * model.absorbPulse
    }

    /// Nil lets the content decide.
    private func fixedHeight(for content: NotchContent) -> CGFloat? {
        let notch = metrics.notchSize.height
        switch content {
        case .retracted:
            return notch - 2
        case .receptive:
            return notch - 2 + 20 * model.reach
        case .compact:
            return notch + 10 * model.absorbPulse
        default:
            return nil
        }
    }

    private func flare(for content: NotchContent) -> CGFloat {
        switch content {
        case .retracted: 0
        case .receptive: 7 * model.reach
        case .compact: 7
        default: 9
        }
    }

    private func bottomRadius(for content: NotchContent) -> CGFloat {
        switch content {
        case .retracted: 8
        case .receptive: 9 + 7 * model.reach
        case .compact: 11
        default: 22
        }
    }

    private func animation(to newContent: NotchContent, from oldContent: NotchContent) -> Animation {
        if newContent == .retracted {
            return model.phase == .detached ? OverlayPhysics.Springs.gulp : OverlayPhysics.Springs.collapse
        }
        if oldContent == .receptive {
            return OverlayPhysics.Springs.gulp
        }
        return newContent > oldContent ? OverlayPhysics.Springs.expand : OverlayPhysics.Springs.collapse
    }

    // MARK: - Top bar (the strip beside the notch)

    private func showsTopBar(_ content: NotchContent) -> Bool {
        switch content {
        case .retracted, .receptive: false
        default: true
        }
    }

    private func topBar(_ content: NotchContent) -> some View {
        HStack(spacing: 0) {
            // The ears fade out while the shape springs and back in once it settles, so nothing
            // inside the notch rides the bounce.
            ZStack(alignment: .leading) {
                leftEar(content)
                    .id(content)
                    .transition(Self.contentTransition)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear
                .frame(width: metrics.notchSize.width)
            ZStack(alignment: .trailing) {
                rightEar(content)
                    .id(content)
                    .transition(Self.contentTransition)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, content == .compact ? 15 : 18)
        .frame(height: metrics.notchSize.height)
    }

    @ViewBuilder
    private func leftEar(_ content: NotchContent) -> some View {
        switch content {
        case .idlePrompt:
            EmptyView()
        case .expanded:
            HStack(spacing: 7) {
                statusGlyph
                elapsedTime
                Text(sessionManager.state == .paused ? "Paused" : "Recording")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        default:
            statusGlyph
        }
    }

    private var statusGlyph: some View {
        NotchStatusGlyph(sessionManager: sessionManager)
    }

    private var elapsedTime: some View {
        NotchElapsedTime(sessionManager: sessionManager)
    }

    @ViewBuilder
    private func rightEar(_ content: NotchContent) -> some View {
        switch content {
        case .idlePrompt:
            EmptyView()
        case .compact, .answer:
            elapsedTime
        case .expanded:
            HStack(spacing: 0) {
                NotchIconButton(systemImage: "stop.fill", help: "Stop meeting", tint: .red) {
                    Task { await sessionManager.stopMeeting() }
                }
                NotchIconButton(systemImage: "gearshape", help: "Settings") {
                    model.isShowingSettings.toggle()
                }
                .popover(
                    isPresented: Binding(get: { model.isShowingSettings }, set: { model.isShowingSettings = $0 }),
                    arrowEdge: .bottom
                ) {
                    OverlaySettingsView(sessionManager: sessionManager)
                }
            }
        default:
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .symbolEffect(
                        .variableColor.iterative.dimInactiveLayers,
                        options: .repeating,
                        isActive: !sessionManager.liveCaptions.isEmpty
                    )
                elapsedTime
            }
        }
    }

    // MARK: - Body

    @ViewBuilder
    private func bodyContent(_ content: NotchContent) -> some View {
        switch content {
        case .retracted, .receptive, .compact:
            EmptyView()
        case .captions:
            VStack(alignment: .leading, spacing: 8) {
                NotchCaptionStack(lines: transcriptLines(limit: 2), previousLineSlots: 1)
                countdownRow
            }
            .padding(.horizontal, 18)
            .padding(.top, 3)
            .padding(.bottom, 13)
            .transition(Self.contentTransition)
        case .expanded:
            VStack(alignment: .leading, spacing: 10) {
                transcriptArea(previousLineSlots: 3)
                if model.isComposing {
                    questionField
                } else {
                    quickActions
                }
                countdownRow
                grabber
            }
            .padding(.horizontal, 18)
            .padding(.top, 3)
            .transition(Self.contentTransition)
        case .answer:
            VStack(alignment: .leading, spacing: 10) {
                answerBody
                // The answer stays on top; the transcript under it drags open like the hover state.
                Rectangle()
                    .fill(.white.opacity(0.1))
                    .frame(height: 1)
                transcriptArea(previousLineSlots: 1)
                countdownRow
                grabber
            }
            .padding(.horizontal, 18)
            .padding(.top, 3)
            .transition(Self.contentTransition)
        case .idlePrompt:
            OverlayIdlePrompt(sessionManager: sessionManager)
                .padding(.horizontal, 18)
                .padding(.top, 2)
                .padding(.bottom, 16)
                .transition(Self.contentTransition)
        }
    }

    /// Content starts appearing after the shape opens, so it doesn't stretch with the outline.
    private static var contentTransition: AnyTransition {
        AnyTransition.asymmetric(
            insertion: AnyTransition.opacity
                .combined(with: .modifier(
                    active: NotchBlur(radius: 3),
                    identity: NotchBlur(radius: 0)
                ))
                .animation(.easeOut(duration: 0.18).delay(0.22)),
            removal: AnyTransition.opacity.animation(.easeOut(duration: 0.08))
        )
    }

    private func playSplash() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { splash = -7 }
        withAnimation(OverlayPhysics.Springs.splash) { splash = 0 }
    }

    /// The live captions, which turn into the scrollable transcript as the notch is dragged
    /// open. Both are always laid out at the same starting height and only cross-fade, so the
    /// drag grows the notch in one motion instead of swapping views.
    private func transcriptArea(previousLineSlots: Int) -> some View {
        let isShowingHistory = model.historyHeight > 0.5
        return ZStack(alignment: .top) {
            NotchTranscriptHistory(lines: transcriptLines(limit: 500))
                .frame(height: max(captionStackHeight + model.historyHeight, 0))
                .opacity(isShowingHistory ? 1 : 0)
                .allowsHitTesting(isShowingHistory)
            NotchCaptionStack(
                lines: transcriptLines(limit: previousLineSlots + 1),
                previousLineSlots: previousLineSlots
            )
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    captionStackHeight = height
                }
                .opacity(isShowingHistory ? 0 : 1)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.14), value: isShowingHistory)
    }

    /// Drag it to make the notch taller and scroll back through the transcript. Dragging
    /// anywhere else on the notch pulls it off instead.
    private var grabber: some View {
        Capsule()
            .fill(.white.opacity(0.22))
            .frame(width: 34, height: 4)
            .frame(width: 120, height: 14)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                withAnimation(OverlayPhysics.Springs.collapse) {
                    model.historyHeight = 0
                }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        controller.resizeChanged(translation: value.translation)
                    }
                    .onEnded { _ in
                        controller.resizeEnded()
                    }
            )
            // The pointer poll shows the resize cursor over this frame (`NotchPanelController`).
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                model.grabberFrame = frame
            }
            .onDisappear { model.grabberFrame = .zero }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)
            .help("Drag to see more of the transcript. Double-click to reset.")
    }

    /// Same height as the chip row, so opening the field doesn't move the notch.
    private var questionField: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            TextField(
                "",
                text: $draftQuestion,
                prompt: Text("Ask about the conversation…").foregroundStyle(.white.opacity(0.38))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(.white)
            .focused($isQuestionFieldFocused)
            .onSubmit(sendQuestion)
            .focusEffectDisabled()
            .writingToolsBehavior(.disabled)
            .onKeyPress(.escape) {
                cancelQuestion()
                return .handled
            }
            Button(action: sendQuestion) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(trimmedDraft.isEmpty ? 0.25 : 0.95))
            }
            .buttonStyle(NotchPressStyle())
            .disabled(trimmedDraft.isEmpty)
            NotchIconButton(systemImage: "xmark", help: "Cancel", action: cancelQuestion)
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(height: 26)
        .background(.white.opacity(0.1), in: Capsule())
        .transition(.opacity)
        .onAppear {
            controller.beginComposing()
            isQuestionFieldFocused = true
        }
    }

    private var trimmedDraft: String {
        draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func startQuestion() {
        draftQuestion = ""
        withAnimation(OverlayPhysics.Springs.content) {
            model.isComposing = true
        }
    }

    private func sendQuestion() {
        let question = trimmedDraft
        guard !question.isEmpty else { return }
        draftQuestion = ""
        controller.endComposing()
        Task { await sessionManager.askQuestion(question) }
    }

    private func cancelQuestion() {
        draftQuestion = ""
        withAnimation(OverlayPhysics.Springs.content) {
            controller.endComposing()
        }
    }

    private var quickActions: some View {
        HStack(spacing: 6) {
            NotchChip(title: "Ask", systemImage: "sparkles", action: startQuestion)
            NotchChip(title: "What to say", systemImage: "text.quote") {
                Task { await sessionManager.askQuestion(OverlayQuickPrompt.whatToSay) }
            }
            NotchChip(title: "Recap", systemImage: "arrow.clockwise") {
                Task { await sessionManager.askQuestion(OverlayQuickPrompt.recap) }
            }
            NotchChip(title: "Screen", systemImage: "camera.viewfinder", action: askAboutScreen)
                .disabled(sessionManager.state != .recording || sessionManager.isCapturingScreen)
            Spacer(minLength: 0)
        }
        .disabled(sessionManager.isAwaitingAnswer)
    }

    private var answerBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 6) {
                if let question = sessionManager.activeQuestion {
                    Text(question)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.09), in: Capsule())
                }
                Spacer(minLength: 0)
                NotchIconButton(systemImage: "xmark", help: "Close") {
                    sessionManager.dismissActiveAnswer()
                }
            }

            if sessionManager.isAwaitingAnswer {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .symbolEffect(.variableColor.iterative.reversing, options: .repeating)
                    Text("Thinking…")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.vertical, 2)
            } else if let answer = sessionManager.activeAnswer {
                NotchAnswerText(text: answer)
            }
        }
    }

    @ViewBuilder
    private var countdownRow: some View {
        if let deadline = sessionManager.autoStopDeadline {
            NotchCountdownRow(deadline: deadline, reason: "Call ended.") {
                sessionManager.keepRecordingAfterCallEnded()
            }
        } else if let deadline = sessionManager.idleStopDeadline {
            NotchCountdownRow(deadline: deadline, reason: "No speech heard.") {
                sessionManager.keepRecordingDespiteSilence()
            }
        }
    }

    // MARK: - Transcript

    private var finalizedTranscript: [ChatMessage] {
        sessionManager.chatMessages.filter { $0.kind == .transcript && !$0.isPartial }
    }

    /// Oldest first; the last line is the newest (live, if someone is speaking).
    private func transcriptLines(limit: Int) -> [NotchTranscriptLine] {
        let finals = finalizedTranscript.suffix(limit).map {
            NotchTranscriptLine(id: $0.id.uuidString, sender: $0.sender, text: $0.text, isLive: false)
        }
        let live = sessionManager.liveCaptions.map {
            NotchTranscriptLine(id: "live-\($0.speaker.label)", sender: $0.speaker, text: $0.text, isLive: true)
        }
        return Array((finals + live).suffix(limit))
    }

    private func startLingering() {
        isLingering = true
        lingerToken += 1
    }

    private func askAboutScreen() {
        Task {
            guard let screenshot = await sessionManager.captureScreenForQuestion() else { return }
            await sessionManager.askQuestion(OverlayQuickPrompt.screen, images: [screenshot])
        }
    }
}

private struct NotchBlur: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}
