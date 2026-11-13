import AppKit
import SwiftUI

private final class KeyablePanel: NSPanel {
    var onImagePaste: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The overlay is carried up into the menu bar to dock it in the notch; AppKit would
    /// otherwise push it back below.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "v",
           !ClipboardImageReader.readImages().isEmpty {
            onImagePaste?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Lets the first click act on a button, so the overlay works without first becoming active
/// while the user is in their call.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The overlay, in whichever form it's in: docked in the notch (`NotchPanelController`) or
/// floating in its own panel. Routes show/hide to the right window and plays the handoffs
/// between them: tearing a drop out of the notch, flinging it, and docking it back.
@MainActor
final class OverlayPanelController: NotchPanelControllerDelegate {
    static let shared = OverlayPanelController()

    let notch = NotchPanelController()
    let motion = OverlayMotion()
    /// Sucks the main window into the notch as a meeting starts, and pours it back out.
    let windowGenie = WindowGenieController()

    private var panel: KeyablePanel?
    private weak var sessionManager: SessionManager?
    private var presentation: OverlayPresentation = .hidden
    private var onImagePaste: (() -> Void)?

    private var windowAnimator: WindowSpringAnimator?
    /// Where the floating overlay last came to rest during this run.
    private var lastFloatingOrigin: CGPoint?
    /// Where the pointer holds the panel (from its top-left) while carrying it out of the notch.
    private var detachedGrabOffset = CGPoint(x: OverlayGlassStyle.panelWidth / 2, y: 18)
    private var isDockReady = false
    private var materializeTask: Task<Void, Never>?
    private var dockTask: Task<Void, Never>?

    /// The window is a fixed-size transparent canvas; SwiftUI draws the dark
    /// panel (at whatever size the content needs) top-anchored inside it. The
    /// window itself never resizes, so the UI can never be clipped by it.
    private static let canvasHeight: CGFloat = OverlayGlassStyle.panelMaxHeightWithPendingImage
    private static let canvasWidth: CGFloat = OverlayGlassStyle.panelWidth

    private init() {
        notch.delegate = self
        windowGenie.onProgress = { [weak self] direction, progress, slide in
            self?.genieProgressed(direction, progress: progress, slide: slide)
        }
        windowGenie.onFinish = { [weak self] direction, completed in
            self?.genieFinished(direction, completed: completed)
        }
    }

    private var dock: OverlayDock {
        sessionManager?.overlayDock ?? .notch
    }

    var isFloatingVisible: Bool {
        panel?.isVisible == true
    }

    func setImagePasteHandler(_ handler: (() -> Void)?) {
        onImagePaste = handler
        panel?.onImagePaste = { [weak self] in
            Task { @MainActor in
                self?.onImagePaste?()
            }
        }
    }

    func configure(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        notch.configure(sessionManager: sessionManager)
        OverlayKeyboardShortcutController.shared.configure(sessionManager: sessionManager)
        rebuildPanelIfNeeded()
        #if DEBUG
        NotchDemoDriver.shared.startIfRequested(sessionManager: sessionManager)
        #endif
    }

    /// Opens on the display under the pointer when it was hidden, or when `followingPointer`
    /// asks to bring it over from another display.
    func show(followingPointer: Bool = false) {
        if followingPointer || presentation == .hidden {
            moveToActiveScreen()
        }
        presentation = .expanded
        if dock == .notch {
            hideFloating()
            notch.present()
        } else {
            notch.retractForFloating()
            showFloating()
        }
    }

    func hide() {
        presentation = .hidden
        hideFloating()
        notch.dismiss()
    }

    func activateForInput() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            ScreenShareExclusion.apply(to: panel)
        }
    }

    /// Gives `SCContentSharingPicker` the key window it needs, in whichever form the overlay is in.
    func presentKeyWindowForPicker() {
        if !(dock == .notch ? notch.isVisible : isFloatingVisible) {
            moveToActiveScreen()
        }
        if dock == .notch {
            notch.makeKeyForPicker()
        } else {
            showFloating()
            activateForInput()
        }
    }

    /// Keeps the overlay out of screenshots. Uses alpha so the panels keep their place and focus.
    func setHiddenForCapture(_ isHidden: Bool) {
        panel?.alphaValue = isHidden ? 0 : 1
        notch.setHiddenForCapture(isHidden)
    }

    func updateForPresentation(_ presentation: OverlayPresentation, maxExpandedHeight: CGFloat? = nil) {
        // Fold/expand is purely a SwiftUI animation; the window never resizes.
        self.presentation = presentation
    }

    // MARK: - Main window ⇄ notch

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// A meeting starting: the main window is sucked up into the notch like minimize sucks a
    /// window into the Dock, and the notch opens into the overlay as it swallows the last of
    /// it. Just hides the window and grows the notch open when the window isn't showing, or
    /// not on the display the notch opens on.
    func showAbsorbingMainWindow() {
        let windows = MainWindowController.shared
        if windowGenie.direction == .expand, let window = windows.window {
            // Started again while the last stop was still pouring out: it turns back around.
            presentation = .expanded
            hideFloating()
            isGenieAbsorbed = false
            _ = windowGenie.collapse(window, into: notch.genieTarget())
            return
        }
        guard !reduceMotion, dock == .notch, let window = windows.window,
              windows.isMainWindowOnScreen, windows.canMorph else {
            genieLog("start: no genie (reduce motion \(reduceMotion), dock \(dock), on screen \(windows.isMainWindowOnScreen), can morph \(windows.canMorph))")
            windows.hideMainWindow()
            show()
            return
        }
        if presentation == .hidden {
            moveToActiveScreen()
        }
        guard Self.screen(containing: window.frame)?.frame == notch.metrics.screenFrame else {
            genieLog("start: no genie (window on another display than the notch)")
            windows.hideMainWindow()
            show()
            return
        }
        presentation = .expanded
        hideFloating()
        isGenieAbsorbed = false
        genieReach = nil
        // Ordered in (and laid out) now, so its first draw doesn't land mid-flight.
        notch.prepareToReceive()
        guard windowGenie.collapse(window, into: notch.genieTarget()) else {
            genieLog("start: genie refused")
            windows.hideMainWindow()
            show()
            return
        }
    }

    /// A meeting stopping: the main window pours back out of the notch into its frame, the
    /// genie in reverse. The floating overlay, if that's where it was, draws into a bead and
    /// goes. Just hides the overlay and shows the window when it can't.
    func hideIntoMainWindow() {
        let windows = MainWindowController.shared
        let isFloatingShowing = dock == .floating && isFloatingVisible
        presentation = .hidden
        if windowGenie.direction == .collapse, let window = windows.window {
            // Stopped before it was all the way in: it pours straight back out.
            notch.beginPouringOut()
            isGenieAbsorbed = false
            _ = windowGenie.expand(window, from: notch.genieTarget())
            return
        }
        // A start that just finished may not have ordered the window out yet.
        windowGenie.finishHiding()
        guard !reduceMotion, let window = windows.window, windows.canMorph,
              !windows.isMainWindowVisible,
              Self.screen(containing: window.frame)?.frame == notch.metrics.screenFrame else {
            genieLog("stop: no genie (visible \(windows.isMainWindowVisible), can morph \(windows.canMorph))")
            hide()
            windows.showMainWindow()
            return
        }
        notch.beginPouringOut()
        genieReach = nil
        guard windowGenie.expand(window, from: notch.genieTarget()) else {
            genieLog("stop: genie refused")
            hide()
            windows.showMainWindow()
            return
        }
        if isFloatingShowing {
            beadAwayFloating()
        } else {
            hideFloating()
        }
    }

    private func genieLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "MeetlyGenieTrace") {
            NSLog("GenieTrace %@", message())
        }
        #endif
    }

    /// The notch opened to take the window (so it isn't opened twice).
    private var isGenieAbsorbed = false
    /// The reach last handed to the notch during a genie, in steps of 0.05, so the notch isn't
    /// re-animated every display frame.
    private var genieReach: CGFloat?

    private func genieProgressed(_ direction: WindowGenieController.Direction, progress: CGFloat, slide: CGFloat) {
        guard presentation != .hidden || direction == .expand else {
            // Hidden (⌘\) on its way in: nothing opens to take it.
            setGenieReach(0)
            return
        }
        if direction == .collapse {
            guard !isGenieAbsorbed else { return }
            if slide >= 0.85 {
                // Most of it is in: the notch gulps and opens over the rest.
                isGenieAbsorbed = true
                notch.absorb()
                return
            }
        }
        // The notch reaches down for the funnel while it's close, and lets go as it leaves.
        setGenieReach(OverlayPhysics.smoothstep(0.15, 0.6, progress))
    }

    private func genieFinished(_ direction: WindowGenieController.Direction, completed: Bool) {
        genieReach = nil
        switch direction {
        case .collapse:
            if presentation == .hidden {
                notch.setReach(0)
            } else if !isGenieAbsorbed {
                // Cut short (e.g. the window was opened from the menu bar): open anyway.
                notch.absorb()
            }
            isGenieAbsorbed = false
        case .expand:
            if presentation == .hidden {
                notch.setReach(0)
            }
            if completed {
                MainWindowController.shared.showMainWindow()
            }
        }
    }

    private func setGenieReach(_ reach: CGFloat) {
        let stepped = (reach * 20).rounded() / 20
        guard stepped != genieReach else { return }
        genieReach = stepped
        notch.setReach(stepped)
    }

    /// The floating overlay draws into a bead and goes, as the meeting it showed ends.
    private func beadAwayFloating() {
        guard let panel else { return }
        materializeTask?.cancel()
        dockTask?.cancel()
        windowAnimator?.stop()
        isDockReady = false
        // On its way out; a click now would grab a panel that's about to be gone.
        panel.ignoresMouseEvents = true
        notch.setBridge(to: nil, reach: 0)
        motion.bead()
        dockTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled, self.presentation == .hidden else { return }
            self.hideFloating()
        }
    }

    /// The display showing most of `frame`. Works for windows that are ordered out too.
    private static func screen(containing frame: CGRect) -> NSScreen? {
        var best: (screen: NSScreen, area: CGFloat)?
        for screen in NSScreen.screens {
            let overlap = screen.frame.intersection(frame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.area ?? 0) {
                best = (screen, area)
            }
        }
        return best?.screen
    }

    // MARK: - Leaving the notch

    /// Pops the overlay out of the notch without a drag: the notch gathers into a bead that
    /// drops, falls to where the floating overlay last was, and splats open into it.
    func popOut() {
        presentation = .expanded
        guard notch.isVisible else {
            sessionManager?.setOverlayDock(.floating)
            showFloating()
            return
        }
        notch.playPopOut { [weak self] drop in
            guard let self else { return }
            self.sessionManager?.setOverlayDock(.floating)
            let start = self.origin(forDrop: drop)
            let target = self.lastFloatingOrigin ?? self.defaultFloatingOrigin()
            self.lastFloatingOrigin = target
            self.materializeFloating(at: start, radius: drop.width / 2)
            guard start.y - target.y > 24 else {
                // Nowhere to fall to: it just springs over and opens.
                self.animator()?.animate(to: target, spring: OverlayPhysics.Springs.windowPopOut)
                self.motion.splat()
                return
            }
            withAnimation(.easeIn(duration: 0.2)) {
                self.motion.dropStretch = 1
            }
            self.animator()?.fall(to: target) { [weak self] speed in
                guard let self else { return }
                self.motion.splat()
                self.animator()?.animate(
                    to: target,
                    initialVelocity: CGVector(dx: 0, dy: min(speed, 1600) * 0.12),
                    spring: OverlayPhysics.Springs.windowLand
                )
            }
        }
    }

    func notchDidTearOff(at mouse: CGPoint, drop: CGRect) {
        presentation = .expanded
        sessionManager?.setOverlayDock(.floating)
        let origin = origin(forDrop: drop)
        // Keep the pointer where it holds the drop, so nothing jumps as it tears.
        detachedGrabOffset = CGPoint(
            x: (mouse.x - origin.x).rounded(),
            y: (origin.y + Self.canvasHeight - mouse.y).rounded()
        )
        materializeFloating(at: origin, radius: drop.width / 2)

        materializeTask = Task { @MainActor [weak self] in
            // One frame as the drop that left the notch, then it splats open under the pointer.
            try? await Task.sleep(for: .milliseconds(16))
            guard let self, !Task.isCancelled else { return }
            self.motion.splat()
        }
    }

    /// The floating panel's origin that puts its drop (top center) exactly on `drop`.
    private func origin(forDrop drop: CGRect) -> CGPoint {
        CGPoint(
            x: (drop.midX - Self.canvasWidth / 2).rounded(),
            y: (drop.maxY - Self.canvasHeight).rounded()
        )
    }

    func notchDetachedDragMoved(to mouse: CGPoint) {
        windowAnimator?.stop()
        panel?.setFrameOrigin(origin(forPointer: mouse))
        floatingDragMoved()
    }

    func notchDetachedDragEnded(velocity: CGVector) {
        floatingDragEnded(velocity: velocity)
    }

    /// Shows the floating panel at `origin` as a drop of notch ink (the bead that tore off).
    /// The caller opens it with `motion.splat()`.
    private func materializeFloating(at origin: CGPoint, radius: CGFloat) {
        rebuildPanelIfNeeded()
        guard let panel else { return }
        windowAnimator?.stop()
        dockTask?.cancel()
        materializeTask?.cancel()
        isDockReady = false

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            motion.setDrop(radius: radius)
        }
        panel.setFrameOrigin(origin)
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        ScreenShareExclusion.apply(to: panel)
        panel.orderFrontRegardless()
    }

    private func origin(forPointer mouse: CGPoint) -> CGPoint {
        CGPoint(
            x: mouse.x - detachedGrabOffset.x,
            y: mouse.y + detachedGrabOffset.y - Self.canvasHeight
        )
    }

    // MARK: - Dragging the floating overlay (called by OverlayWindowDragRegionView)

    func floatingDragBegan() {
        windowAnimator?.stop()
        // Grabbed mid-fall: open it now rather than leaving a drop under the pointer.
        if motion.bloomX < 1 || motion.bloomY < 1 {
            motion.splat()
        }
        dockTask?.cancel()
        isDockReady = false
    }

    /// Call after the panel has moved: the notch reaches toward it when it gets close.
    func floatingDragMoved() {
        // Any display's notch can take it (a MacBook's real one, or another screen's virtual
        // one); the notch moves to whichever the overlay is carried toward.
        let (target, reach) = nearestDock()
        if reach > 0, let target, target != notch.metrics {
            notch.setReach(0)
            notch.move(to: target)
        }
        notch.setReach(reach)
        notch.setBridge(to: reach > 0 ? panel?.frame : nil, reach: reach)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            motion.dockReadiness = reach
        }
        let isReady = reach > 0.6
        if isReady, !isDockReady {
            OverlayPhysics.haptic(.alignment)
        }
        isDockReady = isReady
    }

    /// Docks if released (or thrown) into the notch; otherwise lets it glide to a stop on screen.
    func floatingDragEnded(velocity: CGVector) {
        guard let panel else { return }
        let projectedTop = CGPoint(
            x: panel.frame.midX + OverlayPhysics.project(velocity.dx),
            y: panel.frame.maxY + OverlayPhysics.project(velocity.dy)
        )
        let thrown = nearestDock(forPanelTop: projectedTop)
        if !isDockReady, velocity.dy > 600, thrown.reach > 0.6, let target = thrown.metrics {
            notch.move(to: target)
            dockOverlay(velocity: velocity)
            return
        }
        if isDockReady {
            dockOverlay(velocity: velocity)
            return
        }

        isDockReady = false
        notch.setReach(0)
        notch.setBridge(to: nil, reach: 0)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            motion.dockReadiness = 0
        }
        settle(velocity: velocity)
    }

    /// 0...1: how close the panel's top edge is to the notch. Only rises once the panel is
    /// carried up into the menu bar, so the default spot just below the notch never docks.
    private func nearestDock(forPanelTop top: CGPoint? = nil) -> (metrics: NotchMetrics?, reach: CGFloat) {
        var best: (metrics: NotchMetrics?, reach: CGFloat) = (nil, 0)
        for screen in NSScreen.screens {
            let metrics = NotchMetrics.metrics(for: screen)
            let reach = dockReach(to: metrics, forPanelTop: top)
            if reach > best.reach { best = (metrics, reach) }
        }
        return best
    }

    private func dockReach(to metrics: NotchMetrics, forPanelTop top: CGPoint? = nil) -> CGFloat {
        guard let panel else { return 0 }
        let top = top ?? CGPoint(x: panel.frame.midX, y: panel.frame.maxY)
        guard top.x >= metrics.screenFrame.minX, top.x <= metrics.screenFrame.maxX else { return 0 }
        let rise = top.y - metrics.dockPoint.y
        let vertical = OverlayPhysics.smoothstep(-12, 28, rise)
        let horizontal = 1 - OverlayPhysics.smoothstep(110, 260, abs(top.x - metrics.centerX))
        return vertical * horizontal
    }

    private func settle(velocity: CGVector) {
        guard let panel else { return }
        let current = panel.frame.origin
        let isFling = velocity.magnitude > 500
        var target = current
        if isFling {
            target.x += OverlayPhysics.project(velocity.dx)
            target.y += OverlayPhysics.project(velocity.dy)
        }
        target = clampedOrigin(target)
        lastFloatingOrigin = target
        guard isFling || hypot(target.x - current.x, target.y - current.y) > 0.5 else { return }
        animator()?.animate(
            to: target,
            initialVelocity: isFling ? velocity : .zero,
            spring: OverlayPhysics.Springs.windowFling
        )
    }

    /// Keeps the panel's top edge, where the toolbar is, on screen and out of the notch.
    private func clampedOrigin(_ origin: CGPoint) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.screens.first else { return origin }
        let visible = screen.visibleFrame
        var topLimit = visible.maxY - 8
        // Stay out of every screen's notch area, real or virtual; only a dock goes in there.
        topLimit = min(topLimit, NotchMetrics.metrics(for: screen).dockPoint.y - 8)
        let x = min(max(origin.x, visible.minX + 8), visible.maxX - Self.canvasWidth - 8)
        let top = min(max(origin.y + Self.canvasHeight, visible.minY + 160), topLimit)
        return CGPoint(x: x.rounded(), y: (top - Self.canvasHeight).rounded())
    }

    // MARK: - Docking

    /// Draws the floating overlay back into a drop that flies up into the notch, which
    /// swallows it with a wobble.
    func dockOverlay(velocity: CGVector = .zero) {
        presentation = .expanded
        guard let panel, panel.isVisible else {
            sessionManager?.setOverlayDock(.notch)
            notch.present()
            return
        }
        isDockReady = false
        materializeTask?.cancel()
        // It's on its way into the notch; a click now would grab a panel that is already gone.
        panel.ignoresMouseEvents = true
        notch.setReach(1)

        let metrics = notch.metrics
        let target = CGPoint(
            x: (metrics.centerX - Self.canvasWidth / 2).rounded(),
            y: metrics.screenFrame.maxY - Self.canvasHeight
        )
        notch.setBridge(to: nil, reach: 0)
        animator()?.animate(to: target, initialVelocity: velocity, spring: OverlayPhysics.Springs.windowDock)
        motion.bead()

        // Once it has drawn back into a drop, the notch takes the drop over (same place, same
        // speed) and swallows it, so the merge is one piece of liquid, not a hand-off.
        dockTask?.cancel()
        dockTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled, let panel = self.panel else { return }
            let radius = LiquidDrop.radius
            let center = CGPoint(x: panel.frame.midX, y: panel.frame.maxY - radius)
            let velocity = self.windowAnimator?.currentVelocity ?? .zero
            self.sessionManager?.setOverlayDock(.notch)
            if self.presentation != .hidden {
                self.notch.absorb()
                self.notch.absorbDrop(center: center, radius: radius, velocity: velocity)
            } else {
                self.notch.setReach(0)
            }
            self.finishDock()
        }
    }

    private func finishDock() {
        dockTask = nil
        windowAnimator?.stop()
        panel?.orderOut(nil)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            motion.reset()
        }
    }

    // MARK: - Floating panel

    private func showFloating() {
        rebuildPanelIfNeeded()
        guard let panel else { return }
        dockTask?.cancel()
        if !panel.isVisible {
            windowAnimator?.stop()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                motion.reset()
            }
            panel.setFrameOrigin(lastFloatingOrigin ?? defaultFloatingOrigin())
        }
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        ScreenShareExclusion.apply(to: panel)
        panel.orderFrontRegardless()
    }

    private func hideFloating() {
        materializeTask?.cancel()
        dockTask?.cancel()
        windowAnimator?.stop()
        panel?.orderOut(nil)
        motion.reset()
    }

    private func animator() -> WindowSpringAnimator? {
        if windowAnimator == nil, let panel {
            windowAnimator = WindowSpringAnimator(window: panel)
        }
        return windowAnimator
    }

    /// Whether the overlay is on the display under the pointer (true when nothing is showing).
    var isOnActiveScreen: Bool {
        guard let screen = NotchMetrics.activeScreen() else { return true }
        if dock == .notch {
            return notch.metrics.screenFrame == screen.frame
        }
        guard let panel, panel.isVisible else { return true }
        return screen.frame.contains(Self.topCenter(ofCanvasAt: panel.frame.origin))
    }

    /// Puts the notch, and the floating panel if that's where the overlay lives, on the display
    /// the user is working on. The floating panel keeps its spot if it's already there.
    private func moveToActiveScreen() {
        guard let screen = NotchMetrics.activeScreen() else { return }
        // In floating mode too, so docking flies to this display's notch.
        notch.relocate(to: NotchMetrics.metrics(for: screen))
        guard dock == .floating else { return }
        let isPanelVisible = panel?.isVisible == true
        let current = isPanelVisible ? panel?.frame.origin : lastFloatingOrigin
        if let current, screen.frame.contains(Self.topCenter(ofCanvasAt: current)) { return }
        let origin = defaultFloatingOrigin()
        lastFloatingOrigin = origin
        if isPanelVisible, let panel {
            windowAnimator?.stop()
            panel.setFrameOrigin(origin)
        }
    }

    /// The top middle of the drawn panel, which decides what display it's on.
    private static func topCenter(ofCanvasAt origin: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + canvasWidth / 2, y: origin.y + canvasHeight - 1)
    }

    /// Just below the notch, centered on it.
    private func defaultFloatingOrigin() -> CGPoint {
        let metrics = notch.metrics
        let visible = NSScreen.screens.first(where: { $0.frame == metrics.screenFrame })?.visibleFrame
            ?? metrics.screenFrame
        let top = min(visible.maxY, metrics.dockPoint.y) - 24
        return CGPoint(
            x: (metrics.centerX - Self.canvasWidth / 2).rounded(),
            y: top - Self.canvasHeight
        )
    }

    private func rebuildPanelIfNeeded() {
        guard panel == nil, let sessionManager else { return }

        let contentView = OverlayView(sessionManager: sessionManager)
            .frame(width: OverlayGlassStyle.panelWidth)
            .overlayMotion(motion)
            .environment(motion)
            .preferredColorScheme(.dark)

        let hostingView = FirstMouseHostingView(rootView: contentView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        // The window is a fixed-size canvas; SwiftUI sizes the visible panel.
        hostingView.sizingOptions = []

        let panel = KeyablePanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.canvasWidth,
                height: Self.canvasHeight
            ),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Disabled so the bottom resize handle can receive drags. Move via the toolbar drag region.
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // Keep the overlay on the dark variant regardless of system appearance.
        panel.appearance = NSAppearance(named: .darkAqua)
        let rootView = NSView()
        rootView.wantsLayer = true
        rootView.clipsToBounds = true
        panel.contentView = rootView
        rootView.addSubview(hostingView)

        if let contentView = panel.contentView {
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }

        ScreenShareExclusion.apply(to: panel)
        panel.setFrameOrigin(defaultFloatingOrigin())
        panel.onImagePaste = { [weak self] in
            Task { @MainActor in
                self?.onImagePaste?()
            }
        }
        self.panel = panel
    }
}
