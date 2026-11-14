import AppKit

/// The WindowServer's mesh warp, the call the Dock's genie minimize uses. Private API, looked
/// up at runtime: if a future macOS drops or refuses it, callers fall back to a plain hide/show.
enum WindowWarp {
    /// One mesh point: a point in the window (points, top-left origin) and where it's drawn on
    /// screen (points, CoreGraphics global space: top-left of the primary display, y down).
    /// The WindowServer reads these as 32-bit floats.
    struct Point {
        var localX: Float
        var localY: Float
        var globalX: Float
        var globalY: Float

        init(local: CGPoint, global: CGPoint) {
            localX = Float(local.x)
            localY = Float(local.y)
            globalX = Float(global.x)
            globalY = Float(global.y)
        }
    }

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SetWindowWarp = @convention(c) (Int32, UInt32, Int32, Int32, UnsafeRawPointer?) -> Int32

    private static let symbols: (connection: MainConnectionID, warp: SetWindowWarp)? = {
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connection = dlsym(handle, "CGSMainConnectionID"),
              let warp = dlsym(handle, "CGSSetWindowWarp") else { return nil }
        return (
            unsafeBitCast(connection, to: MainConnectionID.self),
            unsafeBitCast(warp, to: SetWindowWarp.self)
        )
    }()

    /// Warps `window` to a `columns` × `rows` mesh, row-major from the top. False if refused.
    static func set(_ window: NSWindow, columns: Int, rows: Int, mesh: [Point]) -> Bool {
        guard let symbols, window.windowNumber > 0, mesh.count == columns * rows else { return false }
        return mesh.withUnsafeBytes {
            symbols.warp(symbols.connection(), UInt32(window.windowNumber), Int32(columns), Int32(rows), $0.baseAddress) == 0
        }
    }

    /// Removes any warp, so the window draws at its frame again.
    static func clear(_ window: NSWindow) {
        guard let symbols, window.windowNumber > 0 else { return }
        _ = symbols.warp(symbols.connection(), UInt32(window.windowNumber), 0, 0, nil)
    }

    /// `rect` (AppKit screen coordinates, y up) in CoreGraphics global space (y down).
    static func globalRect(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Makes the WindowServer draw a window that's poured out of a warp. A window without a
    /// shadow (the floating overlay) ordered in squeezed into the mouth isn't drawn as the mesh
    /// grows back, until the warp is cleared: the pour-out played invisibly and the panel just
    /// appeared at the end. Turning the shadow on for its first frames fixes that; it's still
    /// squeezed under the notch then, so the shadow never shows. Those frames must draw some of
    /// the window: if the shadow goes off while every row is still piled into the mouth (a
    /// tear-off held right where the notch gave way), it's invisible again.
    struct PourOutKick {
        private var savedShadow: Bool?
        private var framesLeft = 0

        /// Call as the pour-out starts, before the first warp.
        mutating func begin(_ window: NSWindow) {
            guard !window.hasShadow else { return }
            savedShadow = false
            framesLeft = 2
            window.hasShadow = true
        }

        /// Call every display frame, after warping it to `progress`; it ends itself after two
        /// frames that show some of the window.
        mutating func frame(_ window: NSWindow, progress: CGFloat) {
            guard framesLeft > 0, GenieMesh.phases(progress).slide < 0.999 else { return }
            framesLeft -= 1
            if framesLeft == 0 { end(window) }
        }

        /// Call on every way out, too.
        mutating func end(_ window: NSWindow) {
            if let savedShadow {
                window.hasShadow = savedShadow
            }
            savedShadow = nil
            framesLeft = 0
        }
    }
}

/// Where the genie funnels a window into: a horizontal mouth, in CoreGraphics global space.
struct GenieTarget: Equatable {
    var centerX: CGFloat
    /// The mouth's line, just inside the notch so the notch hides it.
    var y: CGFloat
    var width: CGFloat

    /// The display the mouth is on.
    @MainActor
    var screen: NSScreen? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // Just inside the mouth line, so a mouth on a display's top edge counts as on it.
        let point = CGPoint(x: centerX, y: primaryHeight - y - 1)
        return NSScreen.screens.first { $0.frame.contains(point) }
    }
}

/// The macOS minimize "genie", aimed up into the notch. Pure geometry, so it can be stepped and
/// drawn offline. Two overlapping phases of one progress value `g` (0 = the window, 1 = inside
/// the notch): the sides bend into an S-shaped funnel down from the mouth, then the content
/// slides up through it, squeezing into the mouth top rows first.
enum GenieMesh {
    static let columns = 7
    static let rows = 49

    /// How far the sides have bent into the funnel, and how far the content has slid up it.
    static func phases(_ progress: CGFloat) -> (bend: CGFloat, slide: CGFloat) {
        let g = min(max(progress, 0), 1)
        let t = min(max((g - 0.2) / 0.8, 0), 1)
        // Eases in, then keeps its speed into the mouth, so the last rows are sucked in rather
        // than creeping.
        return (OverlayPhysics.smoothstep(0, 0.45, g), t * t * (2 - t))
    }

    /// The mesh for `window` (global space, y down) at `progress`. The identity at 0; at 1
    /// every row is squeezed into the mouth line.
    ///
    /// `contentHeight` is how much of the window, from its top, is drawn: a transparent canvas
    /// (the floating overlay) funnels only its visible part, and the empty rest is folded flat
    /// under it, so the timing follows what you can see. Rows that start above the mouth (a
    /// window carried up into the notch) start on the mouth line, under the notch.
    static func points(
        window: CGRect,
        target: GenieTarget,
        progress: CGFloat,
        contentHeight: CGFloat? = nil
    ) -> [WindowWarp.Point] {
        let (bend, slide) = phases(progress)
        let content = min(max(contentHeight ?? window.height, 1), window.height)
        let hasSpare = content < window.height - 0.5
        let contentRows = hasSpare ? rows - 1 : rows
        let span = max(window.minY + content - target.y, 1)
        let mouthLeft = target.centerX - target.width / 2
        let mouthRight = target.centerX + target.width / 2
        var mesh: [WindowWarp.Point] = []
        mesh.reserveCapacity(columns * rows)
        for row in 0..<rows {
            let isSpare = hasSpare && row == rows - 1
            let drawnY = content * CGFloat(min(row, contentRows - 1)) / CGFloat(contentRows - 1)
            let localY = isSpare ? window.height : drawnY
            // Funnel coordinate: 0 at the mouth, 1 at the drawn bottom edge.
            let rest = max(window.minY + drawnY - target.y, 0) / span
            let u = max(0, rest - slide)
            let y = target.y + u * span
            // The funnel's S-curve: mouth width up top, the window's width at the bottom.
            let e = OverlayPhysics.smoothstep(0, 1, u)
            let funnelLeft = mouthLeft + (window.minX - mouthLeft) * e
            let funnelRight = mouthRight + (window.maxX - mouthRight) * e
            let left = window.minX + (funnelLeft - window.minX) * bend
            let right = window.maxX + (funnelRight - window.maxX) * bend
            for column in 0..<columns {
                let c = CGFloat(column) / CGFloat(columns - 1)
                mesh.append(WindowWarp.Point(
                    local: CGPoint(x: window.width * c, y: localY),
                    global: CGPoint(x: left + (right - left) * c, y: y)
                ))
            }
        }
        return mesh
    }
}

/// Sucks the real main window into the notch like minimize sucks a window into the Dock, and
/// pours it back out. Warps the window itself (no snapshot), so it shows the live page.
///
/// Progress runs on two cascaded, critically damped `LiquidSpring`s stepped per display frame:
/// that eases in and out like the Dock's genie, and turning it around mid-flight keeps its
/// momentum. Every way out (settling, `cancel()`, the watchdog) clears the warp and puts the
/// window's level, mouse and alpha back.
@MainActor
final class WindowGenieController: NSObject {
    enum Direction {
        /// The window is sucked into the notch, and ordered out at the end.
        case collapse
        /// The window pours back out of the notch into its frame.
        case expand
    }

    /// Every frame: the direction, the progress (0 = window, 1 = in the notch) and the slide.
    var onProgress: ((Direction, CGFloat, CGFloat) -> Void)?
    /// When it ends: `completed` is false when `cancel()` cut it short.
    var onFinish: ((Direction, Bool) -> Void)?

    /// Which way it's running; nil when it isn't.
    private(set) var direction: Direction?

    private static let substep = 1.0 / 240
    private let spring: LiquidSpring.Params
    /// This run's spring: `spring`, or a slower one a caller asked for.
    private var runSpring: LiquidSpring.Params
    /// How much of the window, from its top, is drawn (nil: all of it). Read every frame.
    var contentHeight: (() -> CGFloat?)?
    /// Above the menu bar, so the funnel crosses it cleanly, and under the notch (+3), which
    /// hides the mouth.
    private static let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
    /// A collapse aims past the end, so the last rows are sucked in with speed instead of
    /// creeping in on the spring's tail; it finishes as it crosses 1.
    private static let collapseTarget = 1.12
    /// An expand aims a little past 0 too, and finishes once what's left of the bend is under
    /// a point, rather than holding the window click-through for a tail nobody can see.
    private static let expandTarget = -0.03
    private static let expandEnd = 0.005

    private weak var window: NSWindow?
    private var frame: CGRect = .zero
    private var target = GenieTarget(centerX: 0, y: 0, width: 0)
    private var lead = LiquidSpring(0)
    private var progress = LiquidSpring(0)
    private var saved: (level: NSWindow.Level, ignoresMouseEvents: Bool, animation: NSWindow.AnimationBehavior)?
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    /// The expand's first tick only fades the (fully collapsed) window in, giving it a frame to
    /// draw its page while it's still squeezed into the notch.
    private var holdsFirstFrame = false
    private var kick = WindowWarp.PourOutKick()
    private var watchdog: Task<Void, Never>?
    /// A finished collapse leaves the window invisible (alpha 0, still warped into the notch)
    /// rather than ordering it out right away: ordering the key window out stalls the main
    /// thread for a few frames, and the notch is mid-gulp. It's ordered out once that settles,
    /// or straight away when anything else needs the window.
    private var pendingHide: (window: NSWindow, task: Task<Void, Never>)?
    private static let hideDelay: Duration = .seconds(1)

    /// The window is invisible but not ordered out yet, after a collapse.
    var isHidingWindow: Bool {
        pendingHide != nil
    }

    /// `response` 0.5 is about the Dock's minimize; a small panel reads right a little quicker.
    init(response: Double = 0.5) {
        spring = LiquidSpring.Params(response: response, damping: 1)
        runSpring = spring
        super.init()
    }

    #if DEBUG
    /// `-MeetlyGenieSlow YES` runs it ten times slower, to look at the shape.
    private let speed: Double = UserDefaults.standard.bool(forKey: "MeetlyGenieSlow") ? 0.1 : 1
    #else
    private let speed: Double = 1
    #endif

    /// Sucks `window` (on screen) into `target`. False when it can't (the warp was refused, or
    /// the window reaches above the mouth): nothing has changed, so the caller just hides it.
    /// `response` overrides this controller's spring for this run (slower, to be watched).
    func collapse(_ window: NSWindow, into target: GenieTarget, response: Double? = nil) -> Bool {
        if let direction {
            guard window === self.window else { return false }
            if direction == .expand { turn(.collapse) }
            return true
        }
        guard begin(window, target: target, progress: 0) else { return false }
        runSpring = response.map { LiquidSpring.Params(response: $0, damping: 1) } ?? spring
        start(.collapse)
        return true
    }

    /// Pours `window` (ordered out) back out of `target` into its frame. False when it can't:
    /// the window is left as it was, ordered out, for the caller to show plainly. `launched`:
    /// it leaves the mouth already moving, instead of easing out of it from rest, for when it
    /// follows straight on from something going in (the stop's handoff from the overlay).
    func expand(_ window: NSWindow, from target: GenieTarget, launched: Bool = false) -> Bool {
        if let direction {
            guard window === self.window else { return false }
            if direction == .collapse { turn(.expand) }
            return true
        }
        finishHiding()
        window.alphaValue = 0
        kick.begin(window)
        guard begin(window, target: target, progress: 1) else {
            kick.end(window)
            window.alphaValue = 1
            return false
        }
        holdsFirstFrame = true
        runSpring = spring
        if launched {
            // Out of the mouth at once: its first rows hide under the notch, so easing out of
            // it from rest reads as a pause. The lead starts partway out (a velocity alone is
            // soaked up by the damping within a few frames), so only the second spring eases in.
            lead.value = 0.45
            lead.velocity = -1.5
            progress.velocity = -1.5
        }
        start(.expand)
        return true
    }

    /// Stops wherever it is and puts the window back unwarped: ordered out when `hiding`,
    /// otherwise left in or out as it is, for the caller to show or hide.
    func cancel(hiding: Bool = false) {
        finishHiding(orderingOut: hiding)
        finish(completed: false)
    }

    /// Orders out the window a finished collapse left invisible, now rather than later.
    func finishHiding(orderingOut: Bool = true) {
        guard let pending = pendingHide else { return }
        pendingHide = nil
        pending.task.cancel()
        if orderingOut {
            pending.window.orderOut(nil)
        }
        WindowWarp.clear(pending.window)
        restore(pending.window)
    }

    // MARK: - Running

    private func begin(_ window: NSWindow, target: GenieTarget, progress start: CGFloat) -> Bool {
        let frame = WindowWarp.globalRect(window.frame)
        let content = min(contentHeight?() ?? frame.height, frame.height)
        guard frame.width > 1, frame.height > 1, frame.minY + content > target.y + 24 else { return false }
        saved = (window.level, window.ignoresMouseEvents, window.animationBehavior)
        window.ignoresMouseEvents = true
        window.level = Self.level
        // The system's own fade on ordering in and out would play over the genie.
        window.animationBehavior = .none
        if start > 0 {
            window.orderFront(nil)
        }
        let mesh = GenieMesh.points(window: frame, target: target, progress: start, contentHeight: content)
        guard WindowWarp.set(window, columns: GenieMesh.columns, rows: GenieMesh.rows, mesh: mesh) else {
            if start > 0 {
                window.orderOut(nil)
            }
            restore(window)
            return false
        }
        self.window = window
        self.frame = frame
        self.target = target
        lead.snap(Double(start))
        progress.snap(Double(start))
        return true
    }

    private func start(_ direction: Direction) {
        self.direction = direction
        lead.target = direction == .collapse ? Self.collapseTarget : Self.expandTarget
        startWatchdog()
        guard displayLink == nil, let window else { return }
        // Paced by the display the mouth is on, not the window's own link: a window dragged
        // (or flung) mostly off its display stops getting its own frames, which froze the
        // genie until the watchdog cut it to the end.
        let link = target.screen?.displayLink(target: self, selector: #selector(tick(_:)))
            ?? window.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = nil
    }

    /// Turns around mid-flight, keeping the momentum.
    private func turn(_ direction: Direction) {
        self.direction = direction
        lead.target = direction == .collapse ? Self.collapseTarget : Self.expandTarget
        startWatchdog()
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let window, let direction else {
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
            traceFrame(start: tickStart)
            #endif
            return
        }
        let now = link.targetTimestamp
        let frameDuration = max(link.targetTimestamp - link.timestamp, Self.substep)
        // A slow frame (the window's first draw, the notch's first layout) doesn't jump the
        // motion ahead: it picks up one frame on.
        let elapsed = lastTimestamp.map { min(max(now - $0, Self.substep), 1.0 / 30) } ?? frameDuration
        lastTimestamp = now
        var remaining = elapsed * speed
        while remaining > 1e-9 {
            let dt = min(remaining, Self.substep)
            lead.step(dt, runSpring)
            progress.target = lead.value
            progress.step(dt, runSpring)
            remaining -= dt
        }

        let isDone = direction == .collapse ? progress.value >= 1 : progress.value <= Self.expandEnd
        let g = isDone ? (direction == .collapse ? 1 : 0) : CGFloat(min(max(progress.value, 0), 1))
        // Read again every frame, in case the window is moved while it runs. (The tear-off, which
        // pours the overlay out under a moving pointer, has its own driver: `NotchTearOff`.)
        frame = WindowWarp.globalRect(window.frame)
        let mesh = GenieMesh.points(window: frame, target: target, progress: g, contentHeight: contentHeight?())
        let isWarped = WindowWarp.set(window, columns: GenieMesh.columns, rows: GenieMesh.rows, mesh: mesh)
        kick.frame(window, progress: g)
        onProgress?(direction, g, GenieMesh.phases(g).slide)
        #if DEBUG
        traceFrame(start: tickStart)
        #endif
        if isDone || !isWarped {
            #if DEBUG
            if !isWarped, isTracing {
                NSLog("GenieTrace warp refused at g %.3f, window %@, mouth %.0f,%.0f", g, NSStringFromRect(frame), target.centerX, target.y)
            }
            #endif
            // Refused partway (shouldn't happen): skip to the end rather than leave it bent.
            finish(completed: true)
        }
    }

    private func finish(completed: Bool) {
        guard let direction else { return }
        self.direction = nil
        stopLink()
        watchdog?.cancel()
        watchdog = nil
        holdsFirstFrame = false
        #if DEBUG
        let finishStart = CACurrentMediaTime()
        defer {
            if isTracing {
                NSLog("GenieTrace finish took %.2fms", (CACurrentMediaTime() - finishStart) * 1000)
            }
        }
        flushTrace(completed ? "\(direction)" : "\(direction) cancelled")
        #endif
        if let window {
            if completed, direction == .collapse {
                // Invisible now, still warped, so no frame shows it whole; out later.
                window.alphaValue = 0
                let task = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: Self.hideDelay)
                    guard !Task.isCancelled else { return }
                    self?.finishHiding()
                }
                pendingHide = (window, task)
            } else {
                WindowWarp.clear(window)
                if completed, direction == .expand {
                    // Front of the genie level first, so dropping back to its own level leaves
                    // it on top instead of under whatever was there.
                    window.orderFront(nil)
                }
                restore(window)
            }
        }
        window = nil
        onFinish?(direction, completed)
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

    private func startWatchdog() {
        watchdog?.cancel()
        let limit = 2.5 / speed
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard let self, !Task.isCancelled, self.direction != nil else { return }
            self.finish(completed: true)
        }
    }

    private func stopLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    // MARK: - Trace

    #if DEBUG
    /// `-MeetlyGenieTrace YES` logs frame pacing and progress for each genie.
    private let isTracing = UserDefaults.standard.bool(forKey: "MeetlyGenieTrace")
    private var trace: [(gap: Double, work: Double, progress: Double)] = []
    private var lastTickTime: CFTimeInterval?

    private func traceFrame(start: CFTimeInterval) {
        guard isTracing else { return }
        let gap = lastTickTime.map { start - $0 } ?? 0
        lastTickTime = start
        trace.append((gap, CACurrentMediaTime() - start, progress.value))
    }

    private func flushTrace(_ reason: String) {
        defer {
            trace = []
            lastTickTime = nil
        }
        guard isTracing, !trace.isEmpty else { return }
        let lines = trace.map {
            String(format: "%6.1fms gap  %5.2fms work  g %.3f", $0.gap * 1000, $0.work * 1000, $0.progress)
        }
        NSLog("GenieTrace [%@] %d frames\n%@", reason, trace.count, lines.joined(separator: "\n"))
    }
    #endif
}
