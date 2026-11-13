import AppKit
import QuartzCore
import SwiftUI

/// Moves a window with a real spring, frame by frame, so a thrown overlay keeps the pointer's
/// momentum and settles the same way the SwiftUI springs inside it do.
///
/// AppKit only animates window frames along bezier curves, which can't carry a release velocity.
@MainActor
final class WindowSpringAnimator: NSObject {
    private weak var window: NSWindow?
    private var displayLink: CADisplayLink?
    private var position = AnimatablePair<CGFloat, CGFloat>(0, 0)
    private var velocity = AnimatablePair<CGFloat, CGFloat>(0, 0)
    private var target = AnimatablePair<CGFloat, CGFloat>(0, 0)
    private var spring = Spring()
    private var lastTimestamp: CFTimeInterval?
    private var onStep: ((CGPoint) -> Void)?
    private var completion: (() -> Void)?

    init(window: NSWindow) {
        self.window = window
    }

    var isAnimating: Bool {
        displayLink != nil
    }

    /// The window's current speed (points per second, screen coordinates); zero at rest.
    var currentVelocity: CGVector {
        isAnimating ? CGVector(dx: velocity.first, dy: velocity.second) : .zero
    }

    /// Retargets mid-flight without losing speed. `initialVelocity` (points per second)
    /// replaces the current velocity when given.
    func animate(
        to origin: CGPoint,
        initialVelocity: CGVector? = nil,
        spring: Spring,
        onStep: ((CGPoint) -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) {
        guard let window else { return }
        if displayLink == nil {
            position = AnimatablePair(window.frame.origin.x, window.frame.origin.y)
            velocity = AnimatablePair(0, 0)
        }
        if let initialVelocity {
            velocity = AnimatablePair(initialVelocity.dx, initialVelocity.dy)
        }
        target = AnimatablePair(origin.x, origin.y)
        self.spring = spring
        self.onStep = onStep
        self.completion = completion
        startDisplayLinkIfNeeded(for: window)
    }

    /// Stops where the window is now, without calling the completion.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
        onStep = nil
        completion = nil
    }

    private func startDisplayLinkIfNeeded(for window: NSWindow) {
        guard displayLink == nil else { return }
        let link = window.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let deltaTime = min(max(now - (lastTimestamp ?? link.timestamp), 1.0 / 240), 1.0 / 30)
        lastTimestamp = now

        spring.update(value: &position, velocity: &velocity, target: target, deltaTime: deltaTime)

        let distance = hypot(target.first - position.first, target.second - position.second)
        let speed = hypot(velocity.first, velocity.second)
        let isSettled = distance < 0.5 && speed < 5
        if isSettled {
            position = target
        }

        // Snap to device pixels, not whole points, so Retina motion doesn't step in 2px jumps.
        let scale = window?.backingScaleFactor ?? 2
        let origin = CGPoint(
            x: (position.first * scale).rounded() / scale,
            y: (position.second * scale).rounded() / scale
        )
        window?.setFrameOrigin(origin)
        onStep?(origin)

        if isSettled {
            let completion = self.completion
            stop()
            completion?()
        }
    }


    private func snapped(_ point: CGPoint) -> CGPoint {
        let scale = window?.backingScaleFactor ?? 2
        return CGPoint(x: (point.x * scale).rounded() / scale, y: (point.y * scale).rounded() / scale)
    }
}
