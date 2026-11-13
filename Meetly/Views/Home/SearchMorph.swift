import AppKit
import QuartzCore
import SwiftUI

/// One frame of the search morph, in the main window's content coordinates (y down, origin
/// at the window's top-left, under the toolbar).
struct SearchMorphFrame: Equatable {
    /// The shape morphing between the title-bar pill and search mode's field.
    var rect: CGRect = .zero
    var cornerRadius: CGFloat = 0
    /// Once the real field shows, the morph is cut away over it, so only an overshoot past
    /// its edges still draws.
    var cutout: CGRect?

    var isActive: Bool { rect.width > 0.5 && rect.height > 0.5 }
}

/// Per-frame morph state. Only `SearchMorphLayer` reads `frame`, so the rest of the window
/// doesn't re-render every frame; `isRunning` changes only when the morph starts and stops.
@MainActor
@Observable
final class SearchMorphModel {
    var frame = SearchMorphFrame()
    var isRunning = false
}

/// Finds a SwiftUI view's AppKit frame, so rects can be compared across the toolbar's and the
/// page's separate hosting views.
@MainActor
final class LiquidAnchor {
    fileprivate weak var view: NSView?

    /// This anchor's bounds in `space`'s coordinates (y down), if both are in the same window.
    func rect(in space: LiquidAnchor) -> CGRect? {
        guard let view, let target = space.view, let window = view.window, window === target.window else {
            return nil
        }
        return target.convert(view.bounds, from: view)
    }

    var window: NSWindow? { view?.window }
}

struct LiquidAnchorView: NSViewRepresentable {
    let anchor: LiquidAnchor

    func makeNSView(context: Context) -> NSView {
        let view = AnchorNSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }

    private final class AnchorNSView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Morphs the title-bar search pill into search mode's large field and back. The pill's shape
/// is simulated on springs stepped per display frame (see `LiquidSpring`): position, width and
/// height each keep their own velocity, so the shape stretches as it drops, overshoots its
/// width a little and settles, and a close started mid-open carries its momentum back.
@MainActor
final class SearchMorphDriver: NSObject {
    private enum Mode {
        case idle
        /// Pill → field.
        case opening
        /// Field → pill.
        case closing
    }

    let model = SearchMorphModel()
    let canvas = LiquidAnchor()
    let pill = LiquidAnchor()
    let field = LiquidAnchor()

    /// Matches the pill's and the field's corner radii.
    static let pillCorner: CGFloat = 9
    static let fieldCorner: CGFloat = 14

    private static let move = LiquidSpring.Params(response: 0.42, damping: 0.8)
    /// Width leads and overshoots a little; height follows a beat slower.
    private static let widen = LiquidSpring.Params(response: 0.38, damping: 0.68)
    private static let deepen = LiquidSpring.Params(response: 0.46, damping: 0.8)
    private static let narrow = LiquidSpring.Params(response: 0.32, damping: 0.86)
    private static let substep = 1.0 / 240

    private var mode: Mode = .idle
    private var x = LiquidSpring(0)
    private var y = LiquidSpring(0)
    private var width = LiquidSpring(0)
    private var height = LiquidSpring(0)
    private var pillRect: CGRect = .zero
    private var fieldRect: CGRect = .zero
    private var isRevealed = false

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var onRevealed: (() -> Void)?
    private var onFinished: (() -> Void)?

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Morphs the pill into the field. Calls `revealed` once the shape matches the field, so
    /// the real field takes over. Without the geometry (or with Reduce Motion) it calls
    /// `revealed` right away.
    func open(revealed: @escaping () -> Void) {
        guard !reduceMotion, let pillRect = pill.rect(in: canvas), let fieldRect = field.rect(in: canvas) else {
            reset()
            revealed()
            return
        }
        open(from: pillRect, to: fieldRect, revealed: revealed)
        run()
    }

    func open(from pillRect: CGRect, to fieldRect: CGRect, revealed: @escaping () -> Void) {
        self.pillRect = pillRect
        self.fieldRect = fieldRect
        onRevealed = revealed
        onFinished = nil
        isRevealed = false
        if mode == .idle {
            x.snap(pillRect.midX)
            y.snap(pillRect.midY)
            width.snap(pillRect.width)
            height.snap(pillRect.height)
        }
        x.target = fieldRect.midX
        y.target = fieldRect.midY
        width.target = fieldRect.width
        height.target = fieldRect.height
        mode = .opening
    }

    /// Morphs the field back into the pill, then calls `finished` so the pill can show again.
    /// Returns false (and does nothing) without the geometry or with Reduce Motion.
    @discardableResult
    func close(finished: @escaping () -> Void) -> Bool {
        guard !reduceMotion, let pillRect = pill.rect(in: canvas), let fieldRect = field.rect(in: canvas) else {
            reset()
            return false
        }
        close(from: fieldRect, to: pillRect, finished: finished)
        run()
        return true
    }

    func close(from fieldRect: CGRect, to pillRect: CGRect, finished: @escaping () -> Void) {
        self.pillRect = pillRect
        self.fieldRect = fieldRect
        onRevealed = nil
        onFinished = finished
        isRevealed = false
        if mode == .idle {
            x.snap(fieldRect.midX)
            y.snap(fieldRect.midY)
            width.snap(fieldRect.width)
            height.snap(fieldRect.height)
        }
        x.target = pillRect.midX
        y.target = pillRect.midY
        width.target = pillRect.width
        height.target = pillRect.height
        mode = .closing
    }

    func reset() {
        stop()
        mode = .idle
        isRevealed = false
        onRevealed = nil
        onFinished = nil
        model.frame = SearchMorphFrame()
        if model.isRunning { model.isRunning = false }
    }

    // MARK: Frame clock

    private func run() {
        if !model.isRunning { model.isRunning = true }
        publish()
        guard displayLink == nil, let view = canvas.window?.contentView else { return }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
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
        let elapsed = min(max(now - (lastTimestamp ?? link.timestamp), 1.0 / 240), 1.0 / 30)
        lastTimestamp = now
        advance(by: elapsed)
    }

    /// Steps the simulation by `elapsed` seconds, publishes the frame and fires milestones.
    func advance(by elapsed: Double) {
        var remaining = elapsed
        while remaining > 1e-9 {
            let dt = min(remaining, Self.substep)
            integrate(dt)
            remaining -= dt
        }
        publish()
        checkMilestones()
    }

    private func integrate(_ dt: Double) {
        switch mode {
        case .idle:
            return
        case .opening:
            x.step(dt, Self.move)
            y.step(dt, Self.move)
            width.step(dt, Self.widen)
            height.step(dt, Self.deepen)
        case .closing:
            x.step(dt, Self.move)
            y.step(dt, Self.move)
            width.step(dt, Self.narrow)
            height.step(dt, Self.narrow)
        }
    }

    private var isSettled: Bool {
        x.isSettled(within: 0.5, speed: 6) && y.isSettled(within: 0.5, speed: 6)
            && width.isSettled(within: 0.5, speed: 6) && height.isSettled(within: 0.5, speed: 6)
    }

    private func checkMilestones() {
        switch mode {
        case .idle:
            break
        case .opening:
            // The real field takes over once the shape nearly matches it: its background
            // appears at once (same color and shape) and the morph is cut away over it.
            let filled = width.value > fieldRect.width * 0.97 && abs(y.value - fieldRect.midY) < 3
                && height.value > fieldRect.height * 0.94
            if !isRevealed, filled || isSettled {
                isRevealed = true
                publish()
                onRevealed?()
                onRevealed = nil
            }
            if isSettled { reset() }
        case .closing:
            if isSettled {
                let finished = onFinished
                reset()
                finished?()
            }
        }
    }

    private func publish() {
        var frame = SearchMorphFrame()
        let w = max(width.value, 0)
        let h = max(height.value, 0)
        // Stretch along the drop and narrow a touch across it while moving fast, like liquid.
        let stretch = min(abs(y.velocity) / 3200, 0.16)
        let shownWidth = w / (1 + stretch * 0.35)
        let shownHeight = h * (1 + stretch)
        frame.rect = CGRect(x: x.value - shownWidth / 2, y: y.value - shownHeight / 2, width: shownWidth, height: shownHeight)
        // The corner follows the height from the pill's to the field's.
        let progress = min(max((h - pillRect.height) / max(fieldRect.height - pillRect.height, 1), 0), 1)
        frame.cornerRadius = min(Self.pillCorner + (Self.fieldCorner - Self.pillCorner) * progress, shownHeight / 2)
        frame.cutout = isRevealed ? fieldRect : nil
        if frame != model.frame {
            model.frame = frame
        }
    }
}

/// Draws the search morph in the pill's color.
struct SearchMorphLayer: View {
    let model: SearchMorphModel

    var body: some View {
        let morph = model.frame
        Canvas { context, _ in
            guard morph.isActive else { return }
            context.fill(
                Path(roundedRect: morph.rect, cornerRadius: morph.cornerRadius, style: .continuous),
                with: .color(AppTheme.bgInput)
            )
            if let cutout = morph.cutout {
                var cut = context
                cut.blendMode = .destinationOut
                cut.fill(
                    Path(roundedRect: cutout, cornerRadius: SearchMorphDriver.fieldCorner, style: .continuous),
                    with: .color(.black)
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
