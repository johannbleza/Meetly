import AppKit
import SwiftUI

/// Borderless panel that sits over the notch, above the menu bar.
private final class NotchPanel: NSPanel {
    // Only made key on purpose, for the share picker (`makeKeyForPicker`). It has no text
    // fields, so `becomesKeyOnlyIfNeeded` keeps ordinary clicks from taking focus.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The notch lives in the menu-bar strip, which AppKit would otherwise push windows out of.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Callbacks for the overlay being pulled off the notch. The overlay controller pours the
/// floating overlay out of the notch under the pointer and keeps moving it for the rest of the drag.
@MainActor
protocol NotchPanelControllerDelegate: AnyObject {
    func notchDidTearOff(at mouse: CGPoint)
    func notchDetachedDragMoved(to mouse: CGPoint)
    func notchDetachedDragEnded(velocity: CGVector)
}

/// Shows the overlay as a shape growing out of the notch.
///
/// The panel is a fixed transparent canvas (`NotchMetrics.canvasSize`), and SwiftUI draws the
/// notch at whatever size the content needs. Because the canvas covers part of the menu bar,
/// the panel ignores the mouse everywhere except over the drawn shape; a pointer poll decides
/// which, rather than relying on clicks passing through transparent pixels.
@MainActor
final class NotchPanelController {
    let model: NotchModel
    weak var delegate: NotchPanelControllerDelegate?

    private var panel: NotchPanel?
    private weak var sessionManager: SessionManager?
    private var pointerTimer: Timer?
    private var hoverCandidateSince: TimeInterval?
    private var outsideSince: TimeInterval?
    private var isTrackingDrag = false
    private var hasTornOff = false
    /// Screen point where the current pull started.
    private var dragStart: CGPoint?
    private var dragVelocity = VelocityTracker()
    private var orderOutTask: Task<Void, Never>?
    private var presentTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    /// Pulling this far (pointer distance) tears the overlay off.
    private let tearDistance: CGFloat = 120
    /// How far the hovered notch can be dragged open before more drag starts pulling it off.
    static let maxHistoryHeight: CGFloat = 320
    private var historyAtDragStart: CGFloat = 0
    private var growsHistory = false
    /// The next drag came from the bottom pill: it resizes instead of pulling the notch off.
    private var isResizeDrag = false
    /// The screen the notch was last docked on, kept across display changes while it exists.
    private var preferredScreenFrame: CGRect?
    private let hoverDwell: TimeInterval = 0.12
    private let hoverExitDelay: TimeInterval = 0.3
    /// The cursor the pointer poll last set, so leaving the notch restores the arrow once.
    private var shownCursor: NSCursor?

    init() {
        let metrics = NotchMetrics.current() ?? NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            notchSize: CGSize(width: 180, height: 24),
            hasHardwareNotch: false
        )
        model = NotchModel(metrics: metrics)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshMetrics()
            }
        }
    }

    func configure(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    var metrics: NotchMetrics {
        model.metrics
    }

    // MARK: - Presenting

    /// Grows the notch out of the hardware notch (or fades in a virtual one).
    func present() {
        buildPanelIfNeeded()
        guard let panel else { return }
        cancelOrderOut()
        model.phase = .docked

        guard !panel.isVisible || !model.isPresented else { return }
        if !panel.isVisible {
            model.isPresented = false
            model.reach = 0
            model.pull = .zero
            panel.alphaValue = 1
            ScreenShareExclusion.apply(to: panel)
            panel.orderFrontRegardless()
            startPointerTracking()
        }
        // Let one frame draw at notch size so the growth is visible.
        presentTask?.cancel()
        presentTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self, !Task.isCancelled, self.model.phase == .docked else { return }
            withAnimation(OverlayPhysics.Springs.expand) {
                self.model.isPresented = true
            }
        }
    }

    /// Shrinks back into the notch, then orders the panel out.
    func dismiss() {
        presentTask?.cancel()
        guard let panel, panel.isVisible else { return }
        withAnimation(OverlayPhysics.Springs.collapse) {
            model.isPresented = false
            model.isHovering = false
            model.isComposing = false
            model.historyHeight = 0
            model.reach = 0
        }
        scheduleOrderOut(after: 0.45)
    }

    func setHiddenForCapture(_ isHidden: Bool) {
        panel?.alphaValue = isHidden ? 0 : 1
    }

    /// `SCContentSharingPicker` needs a key window or it cancels silently.
    func makeKeyForPicker() {
        present()
        panel?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Typing a question

    /// Opens the question field. The panel is non-activating, so it takes keyboard focus
    /// without pulling the call app out of the foreground.
    func beginComposing() {
        guard let panel else { return }
        model.isComposing = true
        model.isHovering = true
        panel.makeKey()
    }

    func endComposing() {
        model.isComposing = false
        panel?.resignKey()
    }

    // MARK: - Docking the floating overlay back in

    /// The floating overlay is being dragged nearby: reach toward it (0...1).
    func setReach(_ reach: CGFloat) {
        let reach = min(max(reach, 0), 1)
        if reach > 0 {
            buildPanelIfNeeded()
            guard let panel else { return }
            cancelOrderOut()
            if !panel.isVisible {
                model.isPresented = false
                model.phase = .receptive
                panel.alphaValue = 1
                ScreenShareExclusion.apply(to: panel)
                panel.orderFrontRegardless()
                startPointerTracking()
            } else if model.phase != .docked {
                model.phase = .receptive
            }
        }
        guard abs(model.reach - reach) > 0.005 else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
            model.reach = reach
        }
        if reach == 0, model.phase == .receptive {
            scheduleOrderOut(after: 0.4)
        }
    }

    /// Orders the notch in, ready to reach for a window about to be sucked into it, so its
    /// first layout and draw don't land mid-genie and stall it.
    func prepareToReceive() {
        buildPanelIfNeeded()
        guard let panel, !panel.isVisible else { return }
        cancelOrderOut()
        model.isPresented = false
        model.phase = .receptive
        model.reach = 0
        panel.alphaValue = 1
        ScreenShareExclusion.apply(to: panel)
        panel.orderFrontRegardless()
        startPointerTracking()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }

    // MARK: - The main window's genie

    /// Where the main window's genie funnels into (CoreGraphics global space): a mouth a little
    /// narrower than the notch, just inside its bottom edge, so the notch hides it.
    func genieTarget() -> GenieTarget {
        let body = restingBody()
        let canvas = panel?.frame ?? model.metrics.canvasFrame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? canvas.maxY
        let notchBottom = canvas.maxY - body.maxY
        return GenieTarget(
            centerX: canvas.minX + body.midX,
            y: primaryHeight - notchBottom - 4,
            width: max(model.metrics.notchSize.width - 40, 60)
        )
    }

    /// A window (the main window, or the floating overlay) pours back out of the notch: shrink
    /// to a notch reaching for it, which lets go (`setReach`) as the window comes out.
    func beginPouringOut() {
        buildPanelIfNeeded()
        guard let panel else { return }
        cancelOrderOut()
        presentTask?.cancel()
        if !panel.isVisible {
            model.isPresented = false
            model.reach = 0
            model.pull = .zero
            panel.alphaValue = 1
            ScreenShareExclusion.apply(to: panel)
            panel.orderFrontRegardless()
            startPointerTracking()
        }
        model.phase = .receptive
        withAnimation(OverlayPhysics.Springs.collapse) {
            model.isPresented = false
            model.isHovering = false
            model.isComposing = false
            model.historyHeight = 0
            model.reach = 1
        }
    }

    /// A window has been sucked in: the notch gulps and opens with a wobble.
    func absorb() {
        buildPanelIfNeeded()
        guard let panel else { return }
        cancelOrderOut()
        presentTask?.cancel()
        if !panel.isVisible {
            panel.alphaValue = 1
            ScreenShareExclusion.apply(to: panel)
            panel.orderFrontRegardless()
            startPointerTracking()
        }
        model.phase = .docked
        OverlayPhysics.haptic(.alignment)
        withAnimation(.spring(response: 0.16, dampingFraction: 0.9)) {
            model.absorbPulse = 1
            model.reach = 0
        }
        withAnimation(OverlayPhysics.Springs.gulp) {
            model.isPresented = true
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(110))
            withAnimation(OverlayPhysics.Springs.gulp) {
                self?.model.absorbPulse = 0
            }
        }
    }

    /// The hardware notch (or where the virtual one sits), in window coordinates.
    private func restingBody() -> CGRect {
        let notch = model.metrics.notchSize
        return CGRect(
            x: NotchMetrics.canvasSize.width / 2 - notch.width / 2 + 6,
            y: 0,
            width: notch.width - 12,
            height: notch.height
        )
    }

    // MARK: - Pulling the overlay out

    /// The overlay left the notch without a drag (or is being shown floating): just retract.
    func retractForFloating() {
        guard isVisible else { return }
        model.phase = .detached
        withAnimation(OverlayPhysics.Springs.collapse) {
            model.isPresented = false
            model.isHovering = false
            model.isComposing = false
            model.historyHeight = 0
            model.pull = .zero
        }
        scheduleOrderOut(after: 0.5)
    }

    // MARK: - Pulling (called by the notch view's drag gesture)

    /// Works in screen coordinates from `NSEvent.mouseLocation`, because the drag keeps
    /// steering the floating overlay long after it leaves this panel.
    func pullChanged(translation: CGSize, resizing: Bool = false) {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil {
            // The gesture reports its own translation (y down); recover where it began.
            let start = CGPoint(x: mouse.x - translation.width, y: mouse.y + translation.height)
            dragStart = start
            isResizeDrag = resizing
            dragVelocity.reset()
            dragVelocity.add(start)
            isTrackingDrag = true
            hasTornOff = false
            panel?.ignoresMouseEvents = false
            growsHistory = isResizeDrag && model.canGrowHistory
            historyAtDragStart = model.historyHeight
        }
        guard let start = dragStart else { return }
        dragVelocity.add(mouse)
        dragChanged(
            translation: CGSize(width: mouse.x - start.x, height: start.y - mouse.y),
            mouse: mouse
        )
    }

    /// The bottom pill's drag: same tracking as a pull, but it only changes the height.
    func resizeChanged(translation: CGSize) {
        pullChanged(translation: translation, resizing: true)
    }

    func resizeEnded() {
        pullEnded()
    }

    func pullEnded() {
        guard let start = dragStart else { return }
        let mouse = NSEvent.mouseLocation
        dragVelocity.add(mouse)
        dragStart = nil
        dragEnded(
            translation: CGSize(width: mouse.x - start.x, height: start.y - mouse.y),
            velocity: dragVelocity.velocity()
        )
    }

    /// `translation` is in points with down and right positive.
    private func dragChanged(translation: CGSize, mouse: CGPoint) {
        if hasTornOff {
            delegate?.notchDetachedDragMoved(to: mouse)
            return
        }
        guard canTearOff else { return }

        // Dragging the bottom pill only resizes; it never pulls the notch off.
        if isResizeDrag {
            guard growsHistory else { return }
            let wanted = historyAtDragStart + translation.height
            let maxHeight = Self.maxHistoryHeight
            // A tight spring instead of no animation: drag events arrive unevenly, and the
            // spring smooths them into one continuous motion at the display's refresh rate.
            withAnimation(OverlayPhysics.Springs.track) {
                if wanted < 0 {
                    model.historyHeight = -OverlayPhysics.rubberband(-wanted, limit: 14)
                } else if wanted > maxHeight {
                    model.historyHeight = maxHeight + OverlayPhysics.rubberband(wanted - maxHeight, limit: 30)
                } else {
                    model.historyHeight = wanted
                }
            }
            return
        }
        if updatePull(translation) {
            tearOff(at: mouse)
        }
    }

    /// Stretches the notch for a pull of `translation` (down and right positive).
    /// Returns true once it's far enough to tear.
    @discardableResult
    private func updatePull(_ translation: CGSize) -> Bool {
        if translation.height >= tearDistance {
            return true
        }
        let down = max(translation.height, 0)
        let up = min(translation.height, 0)
        // The notch only gives a little, then tears off into the genie.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.pull = CGSize(
                width: OverlayPhysics.rubberband(translation.width, limit: 18),
                height: OverlayPhysics.rubberband(down, limit: 18, coefficient: 0.6)
                    + OverlayPhysics.rubberband(up, limit: 10)
            )
        }
        return false
    }

    /// `velocity` is in AppKit screen coordinates (y up).
    private func dragEnded(translation: CGSize, velocity: CGVector) {
        defer {
            isTrackingDrag = false
            hasTornOff = false
        }

        if hasTornOff {
            delegate?.notchDetachedDragEnded(velocity: velocity)
            return
        }
        let downVelocity = -velocity.dy
        if isResizeDrag {
            isResizeDrag = false
            guard growsHistory else { return }
            // Too small to be useful: close it again. Otherwise it stays where it was let go.
            let settled: CGFloat = model.historyHeight < 40 ? 0 : min(model.historyHeight, Self.maxHistoryHeight)
            withAnimation(OverlayPhysics.Springs.snapBack(displacement: model.historyHeight - settled, velocity: downVelocity)) {
                model.historyHeight = settled
            }
            return
        }
        if canTearOff, translation.height >= 50, downVelocity >= 800 {
            tearOff(at: NSEvent.mouseLocation)
            delegate?.notchDetachedDragEnded(velocity: velocity)
            return
        }

        withAnimation(OverlayPhysics.Springs.snapBack(displacement: model.pull.height, velocity: downVelocity)) {
            model.pull = .zero
        }
    }

    private var canTearOff: Bool {
        model.phase == .docked && model.isPresented
    }

    /// The pull gives way: the notch closes into one reaching for the funnel the floating
    /// overlay pours out of (`setReach` lets it go).
    private func tearOff(at mouse: CGPoint) {
        hasTornOff = true
        OverlayPhysics.haptic(.levelChange)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            model.pull = .zero
        }
        beginPouringOut()
        delegate?.notchDidTearOff(at: mouse)
    }

    // MARK: - Panel

    private func buildPanelIfNeeded() {
        guard panel == nil, let sessionManager else { return }

        let rootView = NotchOverlayView(sessionManager: sessionManager, model: model, controller: self)
            .environment(model)
            .frame(width: NotchMetrics.canvasSize.width, height: NotchMetrics.canvasSize.height)
            .preferredColorScheme(.dark)

        let hostingView = FirstMouseHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: NotchMetrics.canvasSize)
        hostingView.autoresizingMask = [.width, .height]

        let panel = NotchPanel(
            contentRect: model.metrics.canvasFrame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = hostingView
        panel.setFrame(model.metrics.canvasFrame, display: false)
        ScreenShareExclusion.apply(to: panel)
        self.panel = panel
    }

    /// Moves the notch to another display's notch (real or virtual). Only while it isn't showing
    /// content there, e.g. when the floating overlay is being carried toward another screen.
    func move(to metrics: NotchMetrics) {
        guard metrics != model.metrics else { return }
        preferredScreenFrame = metrics.screenFrame
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.reach = 0
            model.metrics = metrics
        }
        panel?.setFrame(metrics.canvasFrame, display: true)
    }

    /// Moves the notch to another display even while it's showing: it closes at once, and the
    /// next `present()` grows it out of the new display's notch.
    func relocate(to metrics: NotchMetrics) {
        guard metrics != model.metrics else { return }
        presentTask?.cancel()
        if model.isComposing {
            endComposing()
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.isPresented = false
            model.isHovering = false
            model.historyHeight = 0
            model.pull = .zero
        }
        move(to: metrics)
    }

    private func refreshMetrics() {
        let preferred = preferredScreenFrame.flatMap { frame in
            NSScreen.screens.first(where: { $0.frame == frame }).map(NotchMetrics.metrics(for:))
        }
        guard let metrics = preferred ?? NotchMetrics.current(), metrics != model.metrics else { return }
        model.metrics = metrics
        panel?.setFrame(metrics.canvasFrame, display: true)
    }

    private func scheduleOrderOut(after delay: TimeInterval) {
        orderOutTask?.cancel()
        orderOutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            // Ordering out mid-drag would strand the drag's event loop.
            while self.isTrackingDrag {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
            }
            guard !self.model.isPresented, self.model.reach == 0 else { return }
            self.panel?.orderOut(nil)
            self.stopPointerTracking()
            self.model.isHovering = false
            self.model.phase = .docked
        }
    }

    private func cancelOrderOut() {
        orderOutTask?.cancel()
        orderOutTask = nil
    }

    // MARK: - Pointer

    private func startPointerTracking() {
        guard pointerTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pointerTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func stopPointerTracking() {
        pointerTimer?.invalidate()
        pointerTimer = nil
        hoverCandidateSince = nil
        outsideSince = nil
        panel?.ignoresMouseEvents = true
        restoreCursor()
    }

    private func pointerTick() {
        guard let panel, panel.isVisible else { return }
        // A gesture can be cancelled without an end callback; don't stay stuck mid-pull.
        if isTrackingDrag, NSEvent.pressedMouseButtons & 1 == 0 {
            pullEnded()
        }
        let mouse = NSEvent.mouseLocation
        let isInside = model.isPresented && model.phase == .docked && hitRect().contains(mouse)

        let ignoresMouse = !(isInside || isTrackingDrag)
        if panel.ignoresMouseEvents != ignoresMouse {
            panel.ignoresMouseEvents = ignoresMouse
        }
        updateCursor(mouse: mouse, isInside: isInside)

        let now = ProcessInfo.processInfo.systemUptime
        if isInside {
            outsideSince = nil
            guard !model.isHovering else { return }
            if let since = hoverCandidateSince {
                if now - since >= hoverDwell {
                    model.isHovering = true
                }
            } else {
                hoverCandidateSince = now
            }
        } else {
            hoverCandidateSince = nil
            guard model.isHovering, !isTrackingDrag, !model.isComposing, !model.isShowingSettings else { return }
            if let since = outsideSince {
                if now - since >= hoverExitDelay {
                    withAnimation(OverlayPhysics.Springs.collapse) {
                        if !model.isShowingAnswer {
                            model.historyHeight = 0
                        }
                        model.isHovering = false
                    }
                    outsideSince = nil
                }
            } else {
                outsideSince = now
            }
        }
    }

    // MARK: - Cursor

    /// The panel flips `ignoresMouseEvents` and is rarely key, so cursor rects and SwiftUI
    /// hover pushes don't stick; the poll sets the cursor itself. Buttons keep their own.
    private func updateCursor(mouse: CGPoint, isInside: Bool) {
        let cursor: NSCursor?
        if isTrackingDrag {
            cursor = isResizeDrag ? .resizeUpDown : .closedHand
        } else if isInside {
            if contains(model.grabberFrame, mouse, padding: 4) {
                cursor = model.canGrowHistory ? .resizeUpDown : .openHand
            } else if model.controlFrames.values.contains(where: { contains($0, mouse, padding: 0) }) {
                shownCursor = nil
                return
            } else {
                cursor = canTearOff ? .openHand : .arrow
            }
        } else {
            restoreCursor()
            return
        }
        // Set every tick while over the notch: AppKit resets to the arrow on mouse moves.
        cursor?.set()
        shownCursor = cursor
    }

    private func restoreCursor() {
        guard let shown = shownCursor else { return }
        shownCursor = nil
        if shown != .arrow { NSCursor.arrow.set() }
    }

    private func contains(_ windowRect: CGRect, _ point: CGPoint, padding: CGFloat) -> Bool {
        guard !windowRect.isEmpty else { return false }
        return screenRect(forWindowRect: windowRect).insetBy(dx: -padding, dy: -padding).contains(point)
    }

    /// The drawn notch in screen coordinates, padded a little so edges are easy to hit.
    private func hitRect() -> CGRect {
        var rect = screenRect(forWindowRect: model.shapeFrame)
        if rect.isEmpty {
            let notch = model.metrics.notchSize
            rect = CGRect(
                x: model.metrics.centerX - notch.width / 2,
                y: model.metrics.screenFrame.maxY - notch.height,
                width: notch.width,
                height: notch.height
            )
        }
        return rect.insetBy(dx: -8, dy: -6)
    }

    /// Converts a frame from SwiftUI's top-left window space into AppKit screen space.
    private func screenRect(forWindowRect rect: CGRect) -> CGRect {
        guard !rect.isEmpty else { return .zero }
        let canvas = panel?.frame ?? model.metrics.canvasFrame
        return CGRect(
            x: canvas.minX + rect.minX,
            y: canvas.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
