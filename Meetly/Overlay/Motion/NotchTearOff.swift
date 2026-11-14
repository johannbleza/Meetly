import AppKit

/// Pulls a window out of the notch with the pointer: the genie in reverse, scrubbed by the drag.
/// The floating overlay, or the main window when the idle notch holds it.
///
/// Once the notch gives way, the panel comes out of the notch's mouth through the genie funnel,
/// and how far it's out follows the pull: further down brings more of it out, back up takes it
/// back in. Past `commitPull` (or let go far enough down, or flicked) it pours the rest of the
/// way out on its own under the pointer; let go before that and it's swallowed back.
///
/// The real window stays parked where it was ordered in, and the mesh alone draws it under the
/// pointer (the drawn frame), so the drag never has to move a warped window. Once it's all the
/// way out it's moved to the drawn frame, where the mesh already draws it, and only then
/// unwarped.
///
/// Every way out (all the way out, back in, `cancel()`, a refused warp, the watchdog) clears the
/// warp and puts the window's level, mouse, animation behavior and alpha back.
@MainActor
final class NotchTearOff: NSObject {
    enum Phase {
        /// The pointer holds it, and how far it's out follows the pull.
        case scrubbing
        /// Pouring the rest of the way out on its own. The pointer may still hold it.
        case committed
        /// Let go too early: it's swallowed back into the notch.
        case returning
    }

    enum Outcome {
        /// All the way out, whole and unwarped at its drawn frame. `isHeld`: the pointer still
        /// holds it, and the drag goes on as a plain floating drag. Otherwise it was let go and is
        /// headed for `restingOrigin` at `velocity` (AppKit points per second).
        case out(isHeld: Bool, restingOrigin: CGPoint?, velocity: CGVector)
        /// Back in the notch. The panel is ordered out.
        case backIn
    }

    /// Pulling this far down (points) gives way: the panel starts coming out.
    static let giveWay: CGFloat = 28
    /// Pulled this far while held, it commits and pours the rest of the way out.
    static let commitPull: CGFloat = 140
    /// Let go after pulling at least this far, it still comes out.
    static let releaseCommitPull: CGFloat = 90
    /// Let go moving down at least this fast (points per second), it comes out.
    static let flickVelocity: CGFloat = 600

    /// How far progress goes while scrubbing, reached at `commitPull`: about half the panel out.
    private static let scrubDepth = 0.35
    /// Tight, so the panel feels attached, but it smooths uneven drag events.
    private static let scrubSpring = LiquidSpring.Params(response: 0.16, damping: 1)
    /// The overlay genie's own timing (`OverlayPanelController.overlayGenie`).
    private static let genieSpring = LiquidSpring.Params(response: 0.42, damping: 1)
    /// The drawn frame after a let-go, like `OverlayPhysics.Springs.windowFling`.
    private static let flingSpring = LiquidSpring.Params(response: 0.55, damping: 0.78)
    /// Aims a little past each end, so it doesn't crawl in on the spring's tail.
    private static let outTarget = -0.03
    private static let outEnd = 0.005
    private static let inTarget = 1.12
    private static let substep = 1.0 / 240
    /// Above the menu bar, so the funnel crosses it cleanly, and under the notch (+3), which
    /// hides the mouth.
    private static let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)

    /// Every frame: the phase, the progress (0 = out, 1 = in the notch) and the genie's slide.
    var onProgress: ((Phase, CGFloat, CGFloat) -> Void)?
    /// It's coming out for good.
    var onCommit: (() -> Void)?
    /// It ended on its own. Not called for `cancel()`.
    var onFinish: ((Outcome) -> Void)?
    /// How much of the panel, from its top, is drawn (nil: all of it). Read every frame.
    var contentHeight: (() -> CGFloat?)?

    private(set) var phase: Phase?

    var isRunning: Bool {
        phase != nil
    }

    private weak var window: NSWindow?
    private var mouth = GenieTarget(centerX: 0, y: 0, width: 0)
    private var lead = LiquidSpring(1)
    private var progress = LiquidSpring(1)
    /// Where the panel is drawn (AppKit points): under the pointer while it's held.
    private var drawnX = LiquidSpring(0)
    private var drawnY = LiquidSpring(0)
    private var pull: CGFloat = 0
    private var isHeld = true
    private var restingOrigin: CGPoint?
    private var saved: (level: NSWindow.Level, ignoresMouseEvents: Bool, animation: NSWindow.AnimationBehavior)?
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    /// The first tick only fades the window in, so its first draw happens while it's still
    /// squeezed into the mouth.
    private var holdsFirstFrame = false
    /// Makes the WindowServer draw the panel as it comes out (`WindowWarp.PourOutKick`).
    private var kick = WindowWarp.PourOutKick()
    private var watchdog: Task<Void, Never>?

    // MARK: - Driving it

    /// Orders `window` in squeezed into `mouth`, to be drawn at `drawnOrigin` as it comes out.
    /// Park the window there first: it isn't moved again until it's all the way out. False when
    /// the warp is refused; the window is then left ordered out.
    func begin(_ window: NSWindow, mouth: GenieTarget, drawnOrigin: CGPoint) -> Bool {
        guard phase == nil else { return false }
        saved = (window.level, window.ignoresMouseEvents, window.animationBehavior)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.level = Self.level
        // The system's own fade on ordering in and out would play over the genie.
        window.animationBehavior = .none
        kick.begin(window)
        // Regardless: the app is rarely active while the notch is dragged.
        window.orderFrontRegardless()
        self.window = window
        self.mouth = mouth
        drawnX.snap(Double(drawnOrigin.x))
        drawnY.snap(Double(drawnOrigin.y))
        lead.snap(1)
        progress.snap(1)
        guard warp(window, progress: 1) else {
            log("warp refused at begin")
            window.orderOut(nil)
            restore(window)
            self.window = nil
            return false
        }
        phase = .scrubbing
        pull = Self.giveWay
        isHeld = true
        restingOrigin = nil
        holdsFirstFrame = true
        startLink()
        return true
    }

    /// The pointer moved: the panel is drawn at `drawnOrigin`, and `pull` (points below where
    /// the pull started) decides how far it's out until it commits.
    func pointerMoved(drawnOrigin: CGPoint, pull: CGFloat) {
        guard let phase, isHeld else { return }
        drawnX.snap(Double(drawnOrigin.x))
        drawnY.snap(Double(drawnOrigin.y))
        self.pull = pull
        if phase == .scrubbing, pull >= Self.commitPull {
            commit()
        }
    }

    /// The pointer let go, moving at `velocity` (AppKit points per second). Far enough down, or
    /// flicked down, it comes out and glides to `restingOrigin`; otherwise it goes back in.
    func released(velocity: CGVector, restingOrigin: CGPoint) {
        guard let phase, isHeld else { return }
        isHeld = false
        switch phase {
        case .scrubbing:
            if pull >= Self.releaseCommitPull || -velocity.dy >= Self.flickVelocity {
                commit()
                letGo(velocity: velocity, toward: restingOrigin)
            } else {
                self.phase = .returning
                lead.target = Self.inTarget
                startWatchdog()
            }
        case .committed:
            letGo(velocity: velocity, toward: restingOrigin)
        case .returning:
            break
        }
    }

    /// Ends it now, for something else that needs the panel. Once committed, it's left whole
    /// and unwarped at its drawn frame (returns true); before that it's ordered out, still in
    /// the notch (false). Doesn't call `onFinish`.
    @discardableResult
    func cancel() -> Bool {
        guard let phase else { return false }
        log("cancelled while \(phase)")
        if phase == .committed {
            handOff(notifying: false)
            return true
        }
        putBack(notifying: false)
        return false
    }

    private func commit() {
        phase = .committed
        lead.target = Self.outTarget
        OverlayPhysics.haptic(.alignment)
        startWatchdog()
        onCommit?()
    }

    private func letGo(velocity: CGVector, toward origin: CGPoint) {
        restingOrigin = origin
        drawnX.target = Double(origin.x)
        drawnY.target = Double(origin.y)
        drawnX.velocity = Double(velocity.dx)
        drawnY.velocity = Double(velocity.dy)
    }

    // MARK: - Frames

    @objc private func tick(_ link: CADisplayLink) {
        guard let window, let phase else {
            stopLink()
            return
        }
        #if DEBUG
        let tickStart = CACurrentMediaTime()
        #endif
        if holdsFirstFrame {
            holdsFirstFrame = false
            window.alphaValue = 1
            lastTimestamp = nil
            #if DEBUG
            traceFrame(start: tickStart, progress: 1)
            #endif
            return
        }
        let now = link.targetTimestamp
        let frameDuration = max(link.targetTimestamp - link.timestamp, Self.substep)
        // A slow frame doesn't jump the motion ahead: it picks up one frame on.
        let elapsed = lastTimestamp.map { min(max(now - $0, Self.substep), 1.0 / 30) } ?? frameDuration
        lastTimestamp = now
        let scrubbed = min(max((pull - Self.giveWay) / (Self.commitPull - Self.giveWay), 0), 1)
        let scrubTarget = 1 - Self.scrubDepth * Double(scrubbed)
        var remaining = elapsed * speed
        while remaining > 1e-9 {
            let dt = min(remaining, Self.substep)
            if phase == .scrubbing {
                progress.target = scrubTarget
                progress.step(dt, Self.scrubSpring)
                // The lead rides along, so committing or letting go carries the momentum on.
                lead.value = progress.value
                lead.velocity = progress.velocity
            } else {
                lead.step(dt, Self.genieSpring)
                progress.target = lead.value
                progress.step(dt, Self.genieSpring)
            }
            if !isHeld, restingOrigin != nil {
                drawnX.step(dt, Self.flingSpring)
                drawnY.step(dt, Self.flingSpring)
            }
            remaining -= dt
        }

        let isOut = phase == .committed && progress.value <= Self.outEnd
        let isIn = phase == .returning && progress.value >= 1
        let g: CGFloat = isOut ? 0 : isIn ? 1 : CGFloat(min(max(progress.value, 0), 1))
        let isWarped = warp(window, progress: g)
        kick.frame(window, progress: g)
        onProgress?(phase, g, GenieMesh.phases(g).slide)
        #if DEBUG
        traceFrame(start: tickStart, progress: g)
        #endif
        // Something the callback did may have ended it.
        guard self.phase != nil else { return }
        if !isWarped {
            // Refused partway (shouldn't happen): end where it was headed rather than leave it bent.
            log("warp refused at g \(g)")
            if phase == .returning {
                putBack()
            } else {
                if phase == .scrubbing { commit() }
                handOff()
            }
        } else if isOut {
            handOff()
        } else if isIn {
            putBack()
        }
    }

    /// Warps the window (wherever it's parked) to be drawn at the drawn frame, `g` of the way
    /// into the mouth.
    private func warp(_ window: NSWindow, progress g: CGFloat) -> Bool {
        let size = window.frame.size
        let drawn = CGRect(x: drawnX.value, y: drawnY.value, width: size.width, height: size.height)
        let mesh = GenieMesh.points(
            window: WindowWarp.globalRect(drawn),
            target: mouth,
            progress: g,
            contentHeight: contentHeight?()
        )
        return WindowWarp.set(window, columns: GenieMesh.columns, rows: GenieMesh.rows, mesh: mesh)
    }

    // MARK: - Ending

    /// All the way out: moved to where it's drawn, then unwarped.
    private func handOff(notifying: Bool = true) {
        guard let window else { return }
        let scale = window.backingScaleFactor
        let origin = CGPoint(
            x: (CGFloat(drawnX.value) * scale).rounded() / scale,
            y: (CGFloat(drawnY.value) * scale).rounded() / scale
        )
        // Moved while the mesh still draws it at that spot, then unwarped there. The move is
        // committed first: a titled window (the main window) otherwise reached the WindowServer
        // after the warp came off, and was drawn for a frame where it had been parked.
        window.setFrameOrigin(origin)
        CATransaction.flush()
        WindowWarp.clear(window)
        // Front of the genie level first, so dropping back to its own level leaves it on top.
        window.orderFrontRegardless()
        let outcome = Outcome.out(
            isHeld: isHeld,
            restingOrigin: isHeld ? nil : restingOrigin,
            velocity: isHeld ? .zero : CGVector(dx: drawnX.velocity, dy: drawnY.velocity)
        )
        end(window, reason: "out")
        if notifying { onFinish?(outcome) }
    }

    /// Back in the notch: hidden while it's still squeezed into the mouth, then unwarped.
    private func putBack(notifying: Bool = true) {
        guard let window else { return }
        window.alphaValue = 0
        window.orderOut(nil)
        WindowWarp.clear(window)
        end(window, reason: "back in")
        if notifying { onFinish?(.backIn) }
    }

    private func end(_ window: NSWindow, reason: String) {
        #if DEBUG
        flushTrace(reason)
        #endif
        phase = nil
        stopLink()
        watchdog?.cancel()
        watchdog = nil
        holdsFirstFrame = false
        restingOrigin = nil
        restore(window)
        self.window = nil
    }

    private func restore(_ window: NSWindow) {
        if let saved {
            window.level = saved.level
            window.ignoresMouseEvents = saved.ignoresMouseEvents
            window.animationBehavior = saved.animation
        }
        saved = nil
        kick.end(window)
        window.alphaValue = 1
    }

    private func startLink() {
        guard displayLink == nil, let window else { return }
        // Paced by the mouth's display, not the window's own link: the window is drawn far from
        // where it's parked, and a window mostly off its display stops getting its own frames.
        let link = mouth.screen?.displayLink(target: self, selector: #selector(tick(_:)))
            ?? window.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = nil
    }

    private func stopLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    /// Only while it runs on its own (committed, or going back in): a held scrub can last as
    /// long as the pointer holds it.
    private func startWatchdog() {
        watchdog?.cancel()
        let limit = 2.5 / speed
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard let self, !Task.isCancelled, let phase = self.phase else { return }
            self.log("watchdog ended it while \(phase)")
            if phase == .returning {
                self.putBack()
            } else {
                self.handOff()
            }
        }
    }

    // MARK: - Trace

    #if DEBUG
    /// `-MeetlyGenieSlow YES` runs it ten times slower, to look at the shape.
    private let speed: Double = UserDefaults.standard.bool(forKey: "MeetlyGenieSlow") ? 0.1 : 1
    /// `-MeetlyGenieTrace YES` logs frame pacing, progress and why it fell back or ended.
    private let isTracing = UserDefaults.standard.bool(forKey: "MeetlyGenieTrace")
    private var trace: [String] = []
    private var lastTickTime: CFTimeInterval?

    private func traceFrame(start: CFTimeInterval, progress g: CGFloat) {
        guard isTracing else { return }
        let gap = lastTickTime.map { start - $0 } ?? 0
        lastTickTime = start
        trace.append(String(
            format: "%6.1fms gap  %5.2fms work  g %.3f  %@  pull %.0f%@",
            gap * 1000,
            (CACurrentMediaTime() - start) * 1000,
            g,
            "\(phase.map { "\($0)" } ?? "-")",
            pull,
            isHeld ? "" : "  let go"
        ))
    }

    private func flushTrace(_ reason: String) {
        defer {
            trace = []
            lastTickTime = nil
        }
        guard isTracing, !trace.isEmpty else { return }
        NSLog("TearOffTrace [%@] %d frames\n%@", reason, trace.count, trace.joined(separator: "\n"))
    }
    #else
    private let speed: Double = 1
    #endif

    private func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        if isTracing {
            NSLog("TearOffTrace %@", message())
        }
        #endif
    }
}
