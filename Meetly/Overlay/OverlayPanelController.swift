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
    /// The same genie for the floating overlay: docking sucks it up into the notch, and
    /// popping out pours it back out.
    let overlayGenie = WindowGenieController(response: 0.42)
    /// Pulling the notch: the floating overlay is pulled out of it by the drag.
    let tearOff = NotchTearOff()
    /// Pulling the idle notch with the main window inside it: the main window is pulled out of
    /// it by the drag instead.
    let windowTearOff = NotchTearOff()

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
        let panelContentHeight: () -> CGFloat? = { [weak self] in
            guard let self else { return nil }
            // The drawn panel plus its shadow; a guess until the view has measured it.
            return self.motion.panelHeight > 0 ? self.motion.panelHeight + 28 : 360
        }
        overlayGenie.contentHeight = panelContentHeight
        tearOff.contentHeight = panelContentHeight
        tearOff.onProgress = { [weak self] phase, progress, slide in
            self?.tearOffProgressed(phase, progress: progress, slide: slide)
        }
        tearOff.onCommit = { [weak self] in
            self?.sessionManager?.setOverlayDock(.floating)
        }
        tearOff.onFinish = { [weak self] outcome in
            self?.tearOffFinished(outcome)
        }
        overlayGenie.onProgress = { [weak self] direction, progress, slide in
            self?.overlayGenieProgressed(direction, progress: progress, slide: slide)
        }
        overlayGenie.onFinish = { [weak self] direction, completed in
            self?.overlayGenieFinished(direction, completed: completed)
        }
        windowTearOff.onProgress = { [weak self] phase, progress, slide in
            self?.windowPullProgressed(phase, progress: progress, slide: slide)
        }
        windowTearOff.onCommit = { [weak self] in
            self?.windowPullCommitted()
        }
        windowTearOff.onFinish = { [weak self] outcome in
            self?.windowPullFinished(outcome)
        }
    }

    private var dock: OverlayDock {
        sessionManager?.overlayDock ?? .notch
    }

    var isFloatingVisible: Bool {
        panel?.isVisible == true && !overlayGenie.isHidingWindow
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
        endTearOff()
        stopHandoff = nil
        motion.holdsMeetingLayout = false
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
        endTearOff()
        // Hidden with the main window inside: it stays hidden, and comes back the usual ways.
        holdsMainWindow = false
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
        endTearOff()
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
    /// not on the display the notch opens on. `reach`: how far the notch already reaches for
    /// the window (it was carried over the notch), which it keeps until it gulps.
    func showAbsorbingMainWindow(reachingFrom reach: CGFloat = 0) {
        let windows = MainWindowController.shared
        endTearOff()
        stopHandoff = nil
        motion.holdsMeetingLayout = false
        holdsMainWindow = false
        genieReachFloor = reach
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
        // The notch opens on the window's display, not the pointer's: after the share picker
        // the pointer is often on the other display (where the picked window was), and the
        // genie can't funnel the window across displays.
        if let screen = Self.screen(containing: window.frame) {
            moveToActiveScreen(screen)
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
    /// genie in reverse. When the floating overlay is showing, it's sucked up into the notch
    /// first and the window pours out as the last of it goes in (`stopHandoff`). Just hides
    /// the overlay and shows the window when it can't.
    func hideIntoMainWindow() {
        let windows = MainWindowController.shared
        // Committed, it's left out whole and goes in with the rest of the floating overlay.
        endTearOff()
        holdsMainWindow = false
        let isFloatingShowing = dock == .floating && isFloatingVisible
        presentation = .hidden
        stopHandoff = nil
        if windowGenie.direction == .collapse, let window = windows.window {
            // Stopped before it was all the way in: it pours straight back out.
            notch.beginPouringOut()
            isGenieAbsorbed = false
            _ = windowGenie.expand(window, from: notch.genieTarget())
            return
        }
        // A start that just finished may not have ordered the window out yet.
        windowGenie.finishHiding()
        if isFloatingShowing, !reduceMotion, suckFloatingInForStop() {
            return
        }
        pourMainWindowOut(fadingFloating: isFloatingShowing)
    }

    /// The floating overlay is sucked up into the notch of the display it's on, like docking,
    /// but the notch doesn't open over it: it hands over to the main window pouring out.
    /// False when the warp can't run.
    private func suckFloatingInForStop() -> Bool {
        guard let panel else { return false }
        // Set before the meeting state changes this turn, so the panel goes in as it was.
        motion.holdsMeetingLayout = true
        windowAnimator?.stop()
        isDockReady = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            motion.dockReadiness = 0
        }
        if overlayGenie.direction == nil {
            let top = Self.topCenter(ofCanvasAt: panel.frame.origin)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(top) }) {
                notch.relocate(to: NotchMetrics.metrics(for: screen))
            }
            notch.prepareToReceive()
        }
        overlayReach = nil
        isOverlayAbsorbed = false
        // The window can pour out of the same notch while the overlay's tail is still going
        // in; on another display it waits for the overlay to be all the way in.
        let window = MainWindowController.shared.window
        let sameDisplay = window.flatMap { Self.screen(containing: $0.frame) }?.frame == notch.metrics.screenFrame
        stopHandoff = sameDisplay ? .early : .whenIn
        // Slower than a dock: it's the whole point of the stop, so it should be watched going in.
        guard overlayGenie.collapse(panel, into: notch.genieTarget(), response: 0.62) else {
            genieLog("stop: overlay genie refused")
            stopHandoff = nil
            return false
        }
        return true
    }

    /// When the main window takes over from the floating overlay being sucked in on stop.
    private enum StopHandoff {
        /// As the overlay's last rows go in (same notch).
        case early
        /// Once the overlay is all the way in (the window pours out on another display).
        case whenIn
    }
    private var stopHandoff: StopHandoff?

    /// Hands the stop over from the overlay's genie to the main window's.
    private func handOffStop() {
        guard stopHandoff != nil else { return }
        stopHandoff = nil
        pourMainWindowOut(fadingFloating: false, launched: true)
    }

    private func pourMainWindowOut(fadingFloating: Bool, launched: Bool = false) {
        let windows = MainWindowController.shared
        let isOverlayGoingIn = overlayGenie.direction == .collapse
        // It pours out on the window's own display: the notch there takes over from the one
        // the meeting was showing on (⌘\ may have brought it to another display).
        if !reduceMotion, !isOverlayGoingIn, let window = windows.window, !windows.isMainWindowVisible,
           let screen = Self.screen(containing: window.frame) {
            notch.relocate(to: NotchMetrics.metrics(for: screen))
        }
        guard !reduceMotion, let window = windows.window, windows.canMorph,
              !windows.isMainWindowVisible,
              Self.screen(containing: window.frame)?.frame == notch.metrics.screenFrame else {
            genieLog("stop: no genie (visible \(windows.isMainWindowVisible), can morph \(windows.canMorph))")
            if !isOverlayGoingIn { hide() } else { notch.dismiss() }
            windows.showMainWindow()
            return
        }
        notch.beginPouringOut()
        genieReach = nil
        genieReachFloor = 0
        guard windowGenie.expand(window, from: notch.genieTarget(), launched: launched) else {
            genieLog("stop: genie refused")
            if !isOverlayGoingIn { hide() } else { notch.dismiss() }
            windows.showMainWindow()
            return
        }
        if isOverlayGoingIn {
            // Its tail finishes going in under the notch as the window comes out.
        } else if fadingFloating {
            fadeAwayFloating()
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
    /// A window dragged over the notch already has it reaching: going in, the notch doesn't let
    /// go of that reach first and then reach again.
    private var genieReachFloor: CGFloat = 0

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

    private var genieWaiters: [CheckedContinuation<Void, Never>] = []

    /// Waits for the main window to be all the way into the notch and ordered out, so the
    /// share picker can open over the notch: it cancels itself when its key window is ordered
    /// out under it. Returns at once when no genie is running. The genie's watchdog bounds it.
    func settleMainWindowIntoNotch() async {
        if windowGenie.direction == .collapse {
            await withCheckedContinuation { genieWaiters.append($0) }
            // Let the notch finish its gulp before ordering the window out stalls a few frames.
            try? await Task.sleep(for: .milliseconds(350))
        }
        guard windowGenie.direction == nil else { return }
        windowGenie.finishHiding()
    }

    private func genieFinished(_ direction: WindowGenieController.Direction, completed: Bool) {
        genieReach = nil
        genieReachFloor = 0
        defer {
            let waiters = genieWaiters
            genieWaiters = []
            waiters.forEach { $0.resume() }
        }
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
        let stepped = (max(reach, genieReachFloor) * 20).rounded() / 20
        guard stepped != genieReach else { return }
        genieReach = stepped
        notch.setReach(stepped)
    }

    /// The floating overlay fades out as the meeting it showed ends, while the main window
    /// pours out of the notch.
    private func fadeAwayFloating() {
        guard let panel else { return }
        overlayGenie.cancel()
        windowAnimator?.stop()
        isDockReady = false
        // On its way out; a click now would grab a panel that's about to be gone.
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.presentation == .hidden else { return }
                self.hideFloating()
            }
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

    // MARK: - The main window into the notch and back out, by hand

    /// The main window is in the notch because it was dragged there, not because a meeting
    /// started: opening it some other way (the menu bar) pours it back out of the notch.
    private(set) var holdsMainWindow = false
    /// How far the notch reaches for the main window being carried over it.
    private var mainWindowReach: CGFloat = 0
    private var isMainWindowDockReady = false
    private var mainWindowAnimator: WindowSpringAnimator?
    /// Where the pointer holds the main window (from its top-left) as it's pulled out of the
    /// notch: the middle of its toolbar.
    private var mainWindowGrabOffset = CGPoint.zero
    /// The notch took the main window back during a pull (so it isn't opened twice).
    private var isWindowPullAbsorbed = false
    /// Where the main window was before a pull parked it under the pointer: a pull that goes
    /// back in puts it back there, so it comes out of the notch later where it went in.
    private var windowPullHome: CGPoint?

    /// Which window the current pull out of the notch brings out.
    private enum PullTarget {
        case overlay
        case mainWindow
    }
    private var pullTarget: PullTarget = .overlay

    /// The main window can go into the notch: not while a summary is being written (the notch
    /// would offer to record), and not while the overlay floats (the notch isn't open then).
    private var canDockMainWindow: Bool {
        guard let sessionManager, sessionManager.state != .summarizing,
              MainWindowController.shared.canMorph else { return false }
        return !(dock == .floating && isFloatingVisible)
    }

    /// The main window is being dragged by its title bar (`MainWindowController`): the notch
    /// reaches for it as the pointer is pushed up into it, like it does for the floating
    /// overlay. The window itself stops under the menu bar, so it's the pointer that asks.
    func mainWindowDragMoved() {
        guard canDockMainWindow, windowGenie.direction == nil, overlayGenie.direction == nil,
              !windowTearOff.isRunning, !tearOff.isRunning else {
            isMainWindowDockReady = false
            setMainWindowReach(0)
            return
        }
        var (target, reach) = mainWindowDock(for: NSEvent.mouseLocation)
        // An open notch stays where it is: only its own display's notch takes the window.
        if notch.model.isPresented, target != notch.metrics {
            reach = 0
        }
        if reach > 0, let target, target != notch.metrics {
            notch.setReach(0)
            notch.move(to: target)
        }
        setMainWindowReach(reach)
        let isReady = reach > 0.6
        if isReady, !isMainWindowDockReady {
            OverlayPhysics.haptic(.alignment)
        }
        isMainWindowDockReady = isReady
    }

    /// The main window was let go. Over the notch, it's sucked in (true); otherwise the notch
    /// lets go of it.
    @discardableResult
    func mainWindowDragEnded() -> Bool {
        let isReady = isMainWindowDockReady
        isMainWindowDockReady = false
        guard isReady, canDockMainWindow, let sessionManager else {
            setMainWindowReach(0)
            return false
        }
        genieLog("main window dropped on the notch (reach \(mainWindowReach))")
        sessionManager.dockMainWindowIntoNotch()
        return true
    }

    /// Sucks the main window into the notch it was dropped on, and the notch opens over the
    /// last of it on whatever it shows: "Ready to record" when there's no meeting. Called by
    /// `SessionManager.dockMainWindowIntoNotch`, which opens the overlay first.
    func dockMainWindow() {
        let reach = mainWindowReach
        mainWindowReach = 0
        mainWindowAnimator?.stop()
        showAbsorbingMainWindow(reachingFrom: reach)
        holdsMainWindow = true
    }

    /// Opened some other way (the menu bar) while it's in the notch it was dragged into: the
    /// main window pours back out of the notch, which closes behind it. False when it isn't in
    /// there, for the caller to just show it.
    func releaseMainWindowFromNotch() -> Bool {
        guard holdsMainWindow else { return false }
        holdsMainWindow = false
        let windows = MainWindowController.shared
        guard let sessionManager, sessionManager.state == .idle, presentation != .hidden,
              !windowTearOff.isRunning,
              !windows.isMainWindowVisible || windowGenie.direction == .collapse else { return false }
        sessionManager.mainWindowLeftNotch()
        hideIntoMainWindow()
        return true
    }

    private func setMainWindowReach(_ reach: CGFloat) {
        guard reach != mainWindowReach else { return }
        mainWindowReach = reach
        notch.setReach(reach)
    }

    /// The notch under the pointer and how strongly it reaches for the main window the pointer
    /// carries: only once the pointer is pushed up into the menu bar, near the notch.
    private func mainWindowDock(for mouse: CGPoint) -> (metrics: NotchMetrics?, reach: CGFloat) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else {
            return (nil, 0)
        }
        let metrics = NotchMetrics.metrics(for: screen)
        let vertical = OverlayPhysics.smoothstep(-8, 14, mouse.y - metrics.dockPoint.y)
        let horizontal = 1 - OverlayPhysics.smoothstep(110, 260, abs(mouse.x - metrics.centerX))
        return (metrics, vertical * horizontal)
    }

    /// Pulling the idle notch brings out the main window when it's in there (hidden), rather
    /// than the floating overlay.
    private var pullsMainWindow: Bool {
        let windows = MainWindowController.shared
        guard sessionManager?.state == .idle, windows.window != nil, windows.canMorph else { return false }
        return !windows.isMainWindowVisible || windowGenie.direction == .collapse
    }

    /// The pull gave way with the main window inside: it starts coming out of the notch's mouth,
    /// drawn under the pointer, which holds its toolbar.
    private func beginWindowPull(at mouse: CGPoint) {
        let windows = MainWindowController.shared
        guard let window = windows.window else { return }
        // Whatever the genie was doing with it (the tail of going in), it starts over in the mouth.
        windowGenie.cancel(hiding: true)
        mainWindowAnimator?.stop()
        mainWindowGrabOffset = CGPoint(x: (window.frame.width / 2).rounded(), y: 26)
        windowPullHome = window.frame.origin
        let origin = mainWindowOrigin(forPointer: mouse, size: window.frame.size)
        // Parked where it'll be drawn: it isn't moved again while it's warped.
        window.setFrameOrigin(origin)
        genieReach = nil
        genieReachFloor = 0
        isWindowPullAbsorbed = false
        guard !reduceMotion, windowTearOff.begin(window, mouth: notch.genieTarget(), drawnOrigin: origin) else {
            genieLog("window pull: no genie (reduce motion \(reduceMotion))")
            // It just appears under the pointer, and the rest of the drag carries it.
            windowPullCommitted()
            notch.setReach(0)
            windows.showMainWindow()
            return
        }
    }

    private func windowPullMoved(to mouse: CGPoint, pull: CGFloat) {
        guard let window = MainWindowController.shared.window else { return }
        let origin = mainWindowOrigin(forPointer: mouse, size: window.frame.size)
        if windowTearOff.isRunning {
            windowTearOff.pointerMoved(drawnOrigin: origin, pull: pull)
            return
        }
        // All the way out (or shown without the genie): the rest of the drag carries the
        // window, and can carry it back up into the notch.
        guard window.isVisible else { return }
        mainWindowAnimator?.stop()
        window.setFrameOrigin(origin)
        mainWindowDragMoved()
    }

    private func windowPullEnded(at mouse: CGPoint, velocity: CGVector) {
        guard let window = MainWindowController.shared.window else { return }
        let size = window.frame.size
        if windowTearOff.isRunning {
            let origin = mainWindowOrigin(forPointer: mouse, size: size)
            windowTearOff.released(
                velocity: velocity,
                restingOrigin: mainWindowRestingOrigin(from: origin, velocity: velocity, size: size)
            )
            return
        }
        guard window.isVisible, !mainWindowDragEnded() else { return }
        settleMainWindow(
            toward: mainWindowRestingOrigin(from: window.frame.origin, velocity: velocity, size: size),
            velocity: velocity.magnitude > 500 ? velocity : .zero
        )
    }

    private func windowPullProgressed(_ phase: NotchTearOff.Phase, progress: CGFloat, slide: CGFloat) {
        if phase == .returning {
            guard !isWindowPullAbsorbed else { return }
            if slide >= 0.85 {
                // Most of it is back in: the notch gulps and opens over the rest.
                isWindowPullAbsorbed = true
                genieReach = nil
                notch.absorb()
                return
            }
        }
        // Reaching down for the funnel while it's close, letting go as it leaves.
        setGenieReach(OverlayPhysics.smoothstep(0.15, 0.6, progress))
    }

    /// It's coming out for good: the notch closes behind it.
    private func windowPullCommitted() {
        windowPullHome = nil
        holdsMainWindow = false
        presentation = .hidden
        sessionManager?.mainWindowLeftNotch()
    }

    private func windowPullFinished(_ outcome: NotchTearOff.Outcome) {
        genieReach = nil
        switch outcome {
        case let .out(isHeld, restingOrigin, velocity):
            notch.setReach(0)
            // Key and in front, with the app active, as if it had been opened.
            MainWindowController.shared.showMainWindow()
            if isHeld {
                // Still in hand: the notch reaches again if it's carried back up.
                mainWindowDragMoved()
            } else if let restingOrigin {
                settleMainWindow(toward: restingOrigin, velocity: velocity)
            }
        case .backIn:
            putMainWindowBackHome()
            if !isWindowPullAbsorbed {
                notch.absorb()
            }
            isWindowPullAbsorbed = false
        }
    }

    /// The pull went back in (the window is ordered out): back to where it was before.
    private func putMainWindowBackHome() {
        if let home = windowPullHome, let window = MainWindowController.shared.window, !window.isVisible {
            window.setFrameOrigin(home)
        }
        windowPullHome = nil
    }

    /// Ends a running pull of the main window for something else that needs it: once committed
    /// it's left out whole where it's drawn, otherwise it's ordered out and the notch reopens.
    func endWindowPull() {
        guard windowTearOff.isRunning else { return }
        let isOut = windowTearOff.cancel()
        genieReach = nil
        isWindowPullAbsorbed = false
        if !isOut {
            putMainWindowBackHome()
        }
        windowPullHome = nil
        if isOut || presentation == .hidden {
            notch.setReach(0)
        } else {
            notch.present()
        }
    }

    /// Where the main window is drawn for the pointer at `mouse`: held by its toolbar, and never
    /// under the menu bar, like a window dragged by its title bar.
    private func mainWindowOrigin(forPointer mouse: CGPoint, size: CGSize) -> CGPoint {
        var origin = CGPoint(
            x: mouse.x - mainWindowGrabOffset.x,
            y: mouse.y + mainWindowGrabOffset.y - size.height
        )
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            origin.y = min(origin.y, screen.visibleFrame.maxY - size.height)
        }
        return origin
    }

    /// Where the main window let go at `origin` comes to rest: carried on by a fling, and on
    /// screen under the menu bar (all of it, when it fits).
    private func mainWindowRestingOrigin(from origin: CGPoint, velocity: CGVector, size: CGSize) -> CGPoint {
        var target = origin
        if velocity.magnitude > 500 {
            target.x += OverlayPhysics.project(velocity.dx)
            target.y += OverlayPhysics.project(velocity.dy)
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.screens.first else { return target }
        let visible = screen.visibleFrame
        let x = size.width < visible.width
            ? min(max(target.x, visible.minX), visible.maxX - size.width)
            : visible.minX
        let top = min(max(target.y + size.height, min(visible.minY + size.height, visible.maxY)), visible.maxY)
        return CGPoint(x: x.rounded(), y: (top - size.height).rounded())
    }

    private func settleMainWindow(toward origin: CGPoint, velocity: CGVector) {
        guard let window = MainWindowController.shared.window else { return }
        let distance = hypot(origin.x - window.frame.origin.x, origin.y - window.frame.origin.y)
        guard distance > 0.5 || velocity.magnitude > 5 else { return }
        mainWindowAnimator?.stop()
        let animator = WindowSpringAnimator(window: window)
        mainWindowAnimator = animator
        animator.animate(to: origin, initialVelocity: velocity, spring: OverlayPhysics.Springs.windowFling)
    }

    // MARK: - Leaving the notch

    /// Pops the overlay out of the notch without a drag: the genie in reverse. The notch
    /// closes into one reaching for the funnel, and the panel pours out of it to where it
    /// last floated.
    func popOut() {
        endTearOff()
        presentation = .expanded
        let target = lastFloatingOrigin ?? defaultFloatingOrigin()
        lastFloatingOrigin = target
        guard notch.isVisible, !reduceMotion else {
            notch.retractForFloating()
            placeFloating(at: target)
            return
        }
        notch.beginPouringOut()
        guard pourOutFloating(at: target) else {
            genieLog("pop out: genie refused")
            notch.setReach(0)
            notch.retractForFloating()
            placeFloating(at: target)
            return
        }
    }

    // MARK: - Pulling it out of the notch (NotchPanelControllerDelegate)

    /// The pull gave way: the panel starts coming out of the notch's mouth, drawn under the
    /// pointer, which holds its toolbar. How far it's out follows the drag (`NotchTearOff`).
    func notchPullGaveWay(at mouse: CGPoint) {
        endTearOff()
        if pullsMainWindow {
            // Not recording, with the main window inside: it's the main window that comes out.
            pullTarget = .mainWindow
            beginWindowPull(at: mouse)
            return
        }
        pullTarget = .overlay
        presentation = .expanded
        detachedGrabOffset = CGPoint(x: Self.canvasWidth / 2, y: 18)
        let origin = origin(forPointer: mouse)
        guard !reduceMotion, beginTearOff(at: origin) else {
            genieLog("tear off: no genie (reduce motion \(reduceMotion))")
            notch.setReach(0)
            placeFloating(at: origin)
            return
        }
    }

    func notchPullMoved(to mouse: CGPoint, pull: CGFloat) {
        if pullTarget == .mainWindow {
            windowPullMoved(to: mouse, pull: pull)
            return
        }
        let origin = origin(forPointer: mouse)
        if tearOff.isRunning {
            tearOff.pointerMoved(drawnOrigin: origin, pull: pull)
            return
        }
        // All the way out (or shown without the genie): the rest is a plain floating drag,
        // which can carry it back up to dock.
        guard let panel, panel.isVisible else { return }
        windowAnimator?.stop()
        panel.setFrameOrigin(origin)
        floatingDragMoved()
    }

    func notchPullEnded(at mouse: CGPoint, pull: CGFloat, velocity: CGVector) {
        if pullTarget == .mainWindow {
            windowPullEnded(at: mouse, velocity: velocity)
            return
        }
        if tearOff.isRunning {
            tearOff.released(
                velocity: velocity,
                restingOrigin: restingOrigin(from: origin(forPointer: mouse), velocity: velocity)
            )
            return
        }
        guard panel?.isVisible == true else { return }
        floatingDragEnded(velocity: velocity)
    }

    /// Orders the panel in squeezed into the notch's mouth, parked at `origin` (where it'll be
    /// drawn as it comes out). False when the warp can't run: the panel is left ordered out.
    private func beginTearOff(at origin: CGPoint) -> Bool {
        rebuildPanelIfNeeded()
        guard let panel else { return false }
        // Whatever it was doing (e.g. the tail of a dock), it starts over squeezed into the mouth.
        panel.alphaValue = 0
        hideFloating()
        isDockReady = false
        // Parked where it'll be drawn: it isn't moved again while it's warped.
        panel.setFrameOrigin(origin)
        panel.ignoresMouseEvents = false
        ScreenShareExclusion.apply(to: panel)
        panel.contentView?.layoutSubtreeIfNeeded()
        overlayReach = nil
        isTearOffAbsorbed = false
        return tearOff.begin(panel, mouth: notch.genieTarget(), drawnOrigin: origin)
    }

    /// Ends a running pull out of the notch (the overlay's or the main window's) for something
    /// else that needs the windows.
    private func endTearOff() {
        endOverlayTearOff()
        endWindowPull()
    }

    /// Ends a running tear-off for something else that needs the panel: once committed it's
    /// left out whole where it's drawn, otherwise it's ordered out (the overlay stays docked).
    private func endOverlayTearOff() {
        guard tearOff.isRunning else { return }
        if tearOff.cancel(), let panel {
            lastFloatingOrigin = panel.frame.origin
        }
        overlayReach = nil
        isTearOffAbsorbed = false
    }

    /// The notch took the overlay back (so it isn't opened twice).
    private var isTearOffAbsorbed = false

    private func tearOffProgressed(_ phase: NotchTearOff.Phase, progress: CGFloat, slide: CGFloat) {
        if phase == .returning {
            guard !isTearOffAbsorbed else { return }
            if slide >= 0.85 {
                // Most of it is back in: the notch gulps and opens over the rest.
                isTearOffAbsorbed = true
                overlayReach = nil
                notch.absorb()
                return
            }
        }
        // Reaching down for the funnel while it's close, letting go as it leaves.
        setOverlayReach(OverlayPhysics.smoothstep(0.15, 0.6, progress))
    }

    private func tearOffFinished(_ outcome: NotchTearOff.Outcome) {
        overlayReach = nil
        switch outcome {
        case let .out(isHeld, restingOrigin, velocity):
            notch.setReach(0)
            guard let panel else { return }
            lastFloatingOrigin = panel.frame.origin
            if isHeld {
                // Still in hand: the notch reaches again if it's carried back up.
                floatingDragMoved()
            } else if let restingOrigin {
                lastFloatingOrigin = restingOrigin
                let distance = hypot(restingOrigin.x - panel.frame.origin.x, restingOrigin.y - panel.frame.origin.y)
                if distance > 0.5 || velocity.magnitude > 5 {
                    animator()?.animate(
                        to: restingOrigin,
                        initialVelocity: velocity,
                        spring: OverlayPhysics.Springs.windowFling
                    )
                }
            }
        case .backIn:
            if !isTearOffAbsorbed {
                notch.absorb()
            }
            isTearOffAbsorbed = false
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                motion.reset()
            }
        }
    }

    /// Pours the floating panel out of the notch's mouth into `origin` (the genie in reverse).
    /// The notch should already be reaching for it (`beginPouringOut`); it lets go as the panel
    /// comes out. False when the warp can't run: the panel is left ordered out.
    private func pourOutFloating(at origin: CGPoint) -> Bool {
        rebuildPanelIfNeeded()
        guard let panel else { return false }
        if overlayGenie.direction == .collapse {
            // Pulled back out while it was still going in: it turns around.
            sessionManager?.setOverlayDock(.floating)
            isOverlayAbsorbed = false
            return overlayGenie.expand(panel, from: notch.genieTarget())
        }
        overlayGenie.finishHiding()
        windowAnimator?.stop()
        isDockReady = false
        motion.reset()
        panel.setFrameOrigin(origin)
        panel.ignoresMouseEvents = false
        ScreenShareExclusion.apply(to: panel)
        panel.contentView?.layoutSubtreeIfNeeded()
        overlayReach = nil
        isOverlayAbsorbed = false
        guard overlayGenie.expand(panel, from: notch.genieTarget()) else { return false }
        sessionManager?.setOverlayDock(.floating)
        return true
    }

    /// Without the genie (Reduce Motion, or the warp refused): the floating panel just appears.
    private func placeFloating(at origin: CGPoint) {
        sessionManager?.setOverlayDock(.floating)
        rebuildPanelIfNeeded()
        guard let panel else { return }
        overlayGenie.cancel(hiding: true)
        windowAnimator?.stop()
        motion.reset()
        panel.setFrameOrigin(origin)
        showFloating()
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
        isDockReady = false
    }

    /// Call after the panel has moved: the notch reaches toward it when it gets close.
    func floatingDragMoved() {
        // Still pouring out of the notch, which is reaching for it.
        guard overlayGenie.direction == nil else { return }
        // Any display's notch can take it (a MacBook's real one, or another screen's virtual
        // one); the notch moves to whichever the overlay is carried toward.
        let (target, reach) = nearestDock()
        if reach > 0, let target, target != notch.metrics {
            notch.setReach(0)
            notch.move(to: target)
        }
        notch.setReach(reach)
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
        if overlayGenie.direction == nil {
            notch.setReach(0)
        }
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
        let target = restingOrigin(from: current, velocity: velocity)
        lastFloatingOrigin = target
        guard isFling || hypot(target.x - current.x, target.y - current.y) > 0.5 else { return }
        animator()?.animate(
            to: target,
            initialVelocity: isFling ? velocity : .zero,
            spring: OverlayPhysics.Springs.windowFling
        )
    }

    /// Where a panel let go at `origin` comes to rest: carried on by a fling, kept on screen.
    private func restingOrigin(from origin: CGPoint, velocity: CGVector) -> CGPoint {
        var target = origin
        if velocity.magnitude > 500 {
            target.x += OverlayPhysics.project(velocity.dx)
            target.y += OverlayPhysics.project(velocity.dy)
        }
        return clampedOrigin(target)
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

    /// Docks like minimize: the floating panel is sucked up into the notch's mouth, and the
    /// notch reaches for it and gulps open over the last of it.
    func dockOverlay(velocity: CGVector = .zero) {
        endTearOff()
        presentation = .expanded
        guard let panel, isFloatingVisible else {
            sessionManager?.setOverlayDock(.notch)
            notch.present()
            return
        }
        if overlayGenie.direction == .collapse { return }
        windowAnimator?.stop()
        isDockReady = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            motion.dockReadiness = 0
        }
        sessionManager?.setOverlayDock(.notch)
        if overlayGenie.direction == .expand {
            // Docked again while it was still pouring out: it turns back around.
            if overlayGenie.collapse(panel, into: notch.genieTarget()) { return }
        }
        // Into the notch of the display it's on, which may not be the one the notch is on.
        let top = Self.topCenter(ofCanvasAt: panel.frame.origin)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(top) }) {
            notch.move(to: NotchMetrics.metrics(for: screen))
        }
        // Ordered in (and laid out) now, so its first draw doesn't land mid-genie.
        notch.prepareToReceive()
        overlayReach = nil
        isOverlayAbsorbed = false
        guard !reduceMotion, overlayGenie.collapse(panel, into: notch.genieTarget()) else {
            genieLog("dock: no genie (reduce motion \(reduceMotion))")
            hideFloating()
            notch.present()
            return
        }
    }

    /// The notch took the floating overlay (so it isn't opened twice).
    private var isOverlayAbsorbed = false
    /// The reach last handed to the notch during the overlay's genie, in steps of 0.05.
    private var overlayReach: CGFloat?

    private func overlayGenieProgressed(_ direction: WindowGenieController.Direction, progress: CGFloat, slide: CGFloat) {
        if let handoff = stopHandoff, direction == .collapse {
            // Sucked in on stop: the notch reaches for it, then the main window takes over.
            if handoff == .early, slide >= 0.65 {
                handOffStop()
            } else {
                setOverlayReach(OverlayPhysics.smoothstep(0.15, 0.6, progress))
            }
            return
        }
        // The main window is pouring out of the notch: it owns the reach.
        if presentation == .hidden, windowGenie.direction == .expand { return }
        guard presentation != .hidden else {
            setOverlayReach(0)
            return
        }
        if direction == .collapse {
            guard !isOverlayAbsorbed else { return }
            if slide >= 0.85 {
                // Most of it is in: the notch gulps and opens over the rest.
                isOverlayAbsorbed = true
                notch.absorb()
                return
            }
        }
        // Reaching down for the funnel while it's close, letting go as it leaves.
        setOverlayReach(OverlayPhysics.smoothstep(0.15, 0.6, progress))
    }

    private func overlayGenieFinished(_ direction: WindowGenieController.Direction, completed: Bool) {
        overlayReach = nil
        if stopHandoff != nil, direction == .collapse {
            // In, or cut short (hidden): the window comes out either way. Showing the overlay
            // again clears the handoff before it cancels this.
            handOffStop()
        }
        switch direction {
        case .collapse:
            if presentation == .hidden {
                // Unless the main window is pouring out of it.
                if windowGenie.direction != .expand { notch.setReach(0) }
            } else if completed, !isOverlayAbsorbed {
                notch.absorb()
            }
            if completed {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    motion.reset()
                }
            }
            isOverlayAbsorbed = false
        case .expand:
            notch.setReach(0)
        }
    }

    private func setOverlayReach(_ reach: CGFloat) {
        let stepped = (reach * 20).rounded() / 20
        guard stepped != overlayReach else { return }
        overlayReach = stepped
        notch.setReach(stepped)
    }

    // MARK: - Floating panel

    private func showFloating() {
        endOverlayTearOff()
        rebuildPanelIfNeeded()
        guard let panel else { return }
        if overlayGenie.direction == .collapse {
            overlayGenie.cancel()
        }
        overlayGenie.finishHiding()
        if !panel.isVisible {
            windowAnimator?.stop()
            motion.reset()
            panel.setFrameOrigin(lastFloatingOrigin ?? defaultFloatingOrigin())
        }
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        ScreenShareExclusion.apply(to: panel)
        panel.orderFrontRegardless()
    }

    private func hideFloating() {
        endOverlayTearOff()
        overlayGenie.cancel(hiding: true)
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
    /// Moves the overlay to `screen`, or by default to the display under the pointer.
    private func moveToActiveScreen(_ screen: NSScreen? = nil) {
        endOverlayTearOff()
        guard let screen = screen ?? NotchMetrics.activeScreen() else { return }
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
