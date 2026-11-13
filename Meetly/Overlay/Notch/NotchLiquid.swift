import AppKit
import QuartzCore
import SwiftUI

/// One frame of the notch's liquid, in the notch panel's window coordinates (y down).
/// `NotchLiquidLayer` melts these together with a goo filter, so necks form, thin and pinch
/// off on their own instead of being drawn as outlines.
struct NotchLiquid: Equatable {
    /// The part of the notch the drop melts into (inside the drawn notch, below its flares).
    var body: CGRect = .zero
    var bodyRadius: CGFloat = 12
    var drop: CGPoint = .zero
    var dropRadius: CGFloat = 0
    /// Moving drops stretch along their motion (0 round) and narrow across it.
    var dropStretch: CGFloat = 0
    var dropAngle: CGFloat = 0
    /// The neck between the notch and the drop: widths where it leaves the notch, at its
    /// middle and where it meets the drop. The middle thins first, and the goo filter drops it
    /// once it's thinner than about the goo radius, so it breaks there, like a liquid thread,
    /// leaving a little cone on each side that pulls back in.
    var neckTop: CGFloat = 0
    var neckMiddle: CGFloat = 0
    var neckBottom: CGFloat = 0
    var strandAnchor: CGPoint = .zero
    /// The floating overlay's frame while it's carried near the notch, and how thick the
    /// liquid bridge reaching down to it is.
    var panel: CGRect?
    var bridgeWidth: CGFloat = 0

    var isActive: Bool {
        dropRadius > 0.5 || (panel != nil && bridgeWidth > 0.5)
    }
}

/// Simulates the notch's drop on springs, one step per display frame: pulled out of the notch,
/// let go back into it, or swallowed when the floating overlay docks. Writes `model.liquid`.
@MainActor
final class NotchLiquidDriver: NSObject {
    enum Mode {
        case idle
        /// Following a pull; the drop hangs from the notch on a thinning strand.
        case pulling
        /// Flowing back into the notch: a released pull, or what's left after a tear.
        case settling
        /// The floating overlay's drop flying into the notch and melting into it.
        case absorbing
    }

    /// Lags the pointer a little and wobbles, so it reads as weight on a thread.
    private static let follow = LiquidSpring.Params(response: 0.2, damping: 0.62)
    private static let grow = LiquidSpring.Params(response: 0.24, damping: 0.7)
    private static let strandSpring = LiquidSpring.Params(response: 0.08, damping: 1)
    private static let flowBack = LiquidSpring.Params(response: 0.3, damping: 0.6)
    private static let drain = LiquidSpring.Params(response: 0.34, damping: 1)
    private static let fly = LiquidSpring.Params(response: 0.24, damping: 0.78)
    private static let substep = 1.0 / 240

    private let model: NotchModel
    private weak var window: NSWindow?
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private(set) var mode: Mode = .idle

    private var x = LiquidSpring(0)
    private var y = LiquidSpring(0)
    private var radius = LiquidSpring(0)
    private var strand = LiquidSpring(0)
    private var body: CGRect = .zero
    private var bodyRadius: CGFloat = 12

    init(model: NotchModel) {
        self.model = model
    }

    func attach(to window: NSWindow) {
        self.window = window
    }

    // MARK: - Pulling

    /// Follows a pull. `progress` is 0 at rest and 1 where the drop tears off; `distance` is
    /// how far the drop hangs below the notch at that point; `sway` its sideways offset.
    func pull(progress: CGFloat, distance: CGFloat, sway: CGFloat, body: CGRect, bodyRadius: CGFloat) {
        if mode != .pulling {
            // Born inside the bottom of the notch, so it swells out of it.
            if mode == .idle {
                x.snap(body.midX)
                y.snap(body.maxY - 16)
                radius.snap(10)
                strand.snap(0)
            }
            mode = .pulling
        }
        self.body = body
        self.bodyRadius = bodyRadius
        let p = min(max(progress, 0), 1)
        radius.target = 12 + (LiquidDrop.radius - 12) * OverlayPhysics.smoothstep(0, 0.65, p)
        x.target = body.midX + sway
        y.target = body.maxY - radius.target * 0.4 + p * distance
        // The neck is thick while the drop still bulges out of the notch, then thins away.
        strand.target = 1 - OverlayPhysics.smoothstep(0.35, 1, p)
        run()
    }

    /// Let go before tearing: the drop flows back up into the notch.
    func release() {
        guard mode == .pulling else { return }
        mode = .settling
        x.target = body.midX
        y.target = body.maxY - 18
        radius.target = 0
        strand.target = 1
        run()
    }

    /// The drop tears off and becomes the floating overlay (or pours into the main window).
    /// Returns it in window coordinates, with its velocity (points per second, y down).
    /// What's left of the thread stays as a small bead on the notch, which is retracting to
    /// `restingBody`, and rides up into it.
    func detach(restingBody: CGRect) -> (center: CGPoint, radius: CGFloat) {
        let drop = (CGPoint(x: x.value, y: y.value), CGFloat(radius.value))
        let anchor = model.liquid.strandAnchor
        mode = .settling
        x.snap(anchor.x)
        y.snap(anchor.y + 4)
        radius.snap(9)
        strand.snap(0)
        body = restingBody
        bodyRadius = 10
        x.target = restingBody.midX
        y.target = restingBody.maxY - 10
        radius.target = 0
        // A thread that just snapped recoils: it starts moving up.
        y.velocity = -260
        run()
        return drop
    }

    // MARK: - Absorbing the floating overlay

    /// The floating overlay, already a drop, hands itself over at `center` (window
    /// coordinates) moving at `velocity` (points per second, y down), and melts into `body`.
    func absorb(center: CGPoint, radius dropRadius: CGFloat, velocity: CGVector, body: CGRect, bodyRadius: CGFloat) {
        mode = .absorbing
        self.body = body
        self.bodyRadius = bodyRadius
        x.snap(center.x)
        y.snap(center.y)
        radius.snap(dropRadius)
        strand.snap(0)
        x.velocity = velocity.dx
        y.velocity = velocity.dy
        x.target = body.midX
        y.target = body.maxY - dropRadius * 0.4
        run()
    }

    // MARK: - Bridge to the floating overlay

    /// The floating overlay is carried near the notch: a liquid bridge reaches down to it.
    func setBridge(panel: CGRect?, width: CGFloat, body: CGRect, bodyRadius: CGFloat) {
        var liquid = model.liquid
        liquid.panel = width > 0.5 ? panel : nil
        liquid.bridgeWidth = width
        if mode == .idle {
            liquid.body = body
            liquid.bodyRadius = bodyRadius
        }
        guard liquid != model.liquid else { return }
        model.liquid = liquid
    }

    /// Clears everything at once, e.g. when the panel is ordered out.
    func reset() {
        stop()
        mode = .idle
        radius.snap(0)
        strand.snap(0)
        model.liquid = NotchLiquid()
    }

    // MARK: - Frame clock

    private func run() {
        guard displayLink == nil, let window else {
            publish()
            return
        }
        let link = window.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = nil
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        var remaining = min(max(now - (lastTimestamp ?? link.timestamp), 1.0 / 240), 1.0 / 30)
        lastTimestamp = now
        while remaining > 1e-9 {
            let dt = min(remaining, Self.substep)
            integrate(dt)
            remaining -= dt
        }
        publish()

        let isDone = mode != .pulling && radius.value < 0.4 && radius.target == 0
        if isDone {
            mode = .idle
            radius.snap(0)
            strand.snap(0)
            publish()
            stop()
        }
    }

    private func integrate(_ dt: Double) {
        switch mode {
        case .idle:
            return
        case .pulling:
            x.step(dt, Self.follow)
            y.step(dt, Self.follow)
            radius.step(dt, Self.grow)
        case .settling:
            x.step(dt, Self.flowBack)
            y.step(dt, Self.flowBack)
            radius.step(dt, Self.drain)
        case .absorbing:
            x.step(dt, Self.fly)
            y.step(dt, Self.fly)
            // It keeps its size until it reaches the notch, then drains into it.
            if y.value < body.maxY + radius.value * 0.5 {
                radius.target = 0
            }
            radius.step(dt, Self.drain)
        }
        strand.step(dt, Self.strandSpring)
    }

    private func publish() {
        var liquid = model.liquid
        liquid.body = body
        liquid.bodyRadius = bodyRadius
        liquid.drop = CGPoint(x: x.value, y: y.value)
        liquid.dropRadius = max(radius.value, 0)
        // Volume-preserving stretch along the motion: fast drops elongate, then round out.
        let speed = hypot(x.velocity, y.velocity)
        liquid.dropStretch = min(speed / 2400, 0.32)
        liquid.dropAngle = atan2(y.velocity, x.velocity)
        let thickness = min(max(strand.value, 0), 1.2)
        let r = liquid.dropRadius
        // Wide where it sags out of the notch, narrowest in the middle.
        liquid.neckTop = r * (0.6 + 1.6 * thickness)
        liquid.neckMiddle = r * 1.2 * pow(thickness, 1.3)
        liquid.neckBottom = r * (0.5 + 0.7 * thickness)
        liquid.strandAnchor = CGPoint(x: body.midX + (x.value - body.midX) * 0.35, y: body.maxY - 6)
        if liquid != model.liquid {
            model.liquid = liquid
        }
    }
}

/// Draws `NotchLiquid` as one piece of liquid: everything is blurred together and cut at half
/// alpha, so nearby shapes melt into each other with smooth necks (metaballs).
struct NotchLiquidLayer: View {
    let model: NotchModel

    var body: some View {
        let liquid = model.liquid
        Canvas { context, _ in
            guard liquid.isActive else { return }
            context.drawLayer { goo in
                goo.addFilter(.alphaThreshold(min: 0.5, color: .black))
                goo.addFilter(.blur(radius: LiquidDrop.goo))
                goo.drawLayer { shapes in
                    let ink = GraphicsContext.Shading.color(.black)
                    shapes.fill(
                        Path(roundedRect: liquid.body, cornerRadius: liquid.bodyRadius, style: .continuous),
                        with: ink
                    )
                    if liquid.dropRadius > 0.5 {
                        shapes.fill(
                            Self.neck(
                                from: liquid.strandAnchor,
                                to: liquid.drop,
                                widths: (liquid.neckTop, liquid.neckMiddle, liquid.neckBottom)
                            ),
                            with: ink
                        )
                        var drop = shapes
                        drop.translateBy(x: liquid.drop.x, y: liquid.drop.y)
                        drop.rotate(by: .radians(liquid.dropAngle))
                        let along = liquid.dropRadius * (1 + liquid.dropStretch)
                        let across = liquid.dropRadius / (1 + liquid.dropStretch)
                        drop.fill(Path(ellipseIn: CGRect(x: -along, y: -across, width: along * 2, height: across * 2)), with: ink)
                    }
                    if let panel = liquid.panel, liquid.bridgeWidth > 0.5 {
                        var bridge = Path()
                        bridge.move(to: CGPoint(x: liquid.body.midX, y: liquid.body.maxY - 4))
                        bridge.addLine(to: CGPoint(x: panel.midX, y: panel.minY + 8))
                        shapes.stroke(bridge, with: ink, style: StrokeStyle(lineWidth: liquid.bridgeWidth, lineCap: .round))
                        // The panel's top edge, so a thick bridge spreads into it with a meniscus.
                        // A thin one doesn't, or the edge alone would bead up on the panel.
                        if liquid.bridgeWidth > 12 {
                            let edge = CGRect(x: panel.minX, y: panel.minY, width: panel.width, height: 24)
                            shapes.fill(Path(roundedRect: edge, cornerRadius: OverlayGlassStyle.cornerRadius), with: ink)
                        }
                    }
                }
            }
            if let panel = liquid.panel {
                // The panel itself shows through; only the bridge above it is drawn.
                var cut = context
                cut.blendMode = .destinationOut
                cut.fill(
                    Path(roundedRect: panel, cornerRadius: OverlayGlassStyle.cornerRadius, style: .continuous),
                    with: .color(.black)
                )
            }
        }
        .allowsHitTesting(false)
    }

    /// A neck from `start` to `end` with the given widths at its start, middle and end; its
    /// sides curve smoothly through the middle.
    private static func neck(from start: CGPoint, to end: CGPoint, widths: (CGFloat, CGFloat, CGFloat)) -> Path {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1 else { return Path() }
        let normal = CGPoint(x: -dy / length, y: dx / length)
        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        func side(_ point: CGPoint, _ width: CGFloat, _ sign: CGFloat) -> CGPoint {
            CGPoint(x: point.x + normal.x * width / 2 * sign, y: point.y + normal.y * width / 2 * sign)
        }
        /// The control point that makes a quadratic curve pass through `through` halfway.
        func control(_ from: CGPoint, _ through: CGPoint, _ to: CGPoint) -> CGPoint {
            CGPoint(x: 2 * through.x - (from.x + to.x) / 2, y: 2 * through.y - (from.y + to.y) / 2)
        }
        let a1 = side(start, widths.0, 1), m1 = side(middle, widths.1, 1), b1 = side(end, widths.2, 1)
        let a2 = side(start, widths.0, -1), m2 = side(middle, widths.1, -1), b2 = side(end, widths.2, -1)
        var path = Path()
        path.move(to: a1)
        path.addQuadCurve(to: b1, control: control(a1, m1, b1))
        path.addLine(to: b2)
        path.addQuadCurve(to: a2, control: control(b2, m2, a2))
        path.closeSubpath()
        return path
    }
}
