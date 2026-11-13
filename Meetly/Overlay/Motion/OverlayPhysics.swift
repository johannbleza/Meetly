import AppKit
import SwiftUI

/// Shared motion math for the notch and the floating overlay, so drags, flings and morphs
/// all come from the same springs and feel like one material.
enum OverlayPhysics {
    /// iOS-style rubber band: follows the pointer at first, then resists, never passing `limit`.
    static func rubberband(_ offset: CGFloat, limit: CGFloat, coefficient: CGFloat = 0.55) -> CGFloat {
        guard limit > 0 else { return 0 }
        let sign: CGFloat = offset < 0 ? -1 : 1
        let distance = abs(offset)
        return sign * (1 - 1 / (distance * coefficient / limit + 1)) * limit
    }

    /// How far a flick carries before friction stops it (UIScrollView's projection).
    static func project(_ velocity: CGFloat, decelerationRate: CGFloat = 0.99) -> CGFloat {
        (velocity / 1000) * decelerationRate / (1 - decelerationRate)
    }

    /// 0 below `lower`, 1 above `upper`, smooth in between.
    static func smoothstep(_ lower: CGFloat, _ upper: CGFloat, _ value: CGFloat) -> CGFloat {
        let t = min(max((value - lower) / (upper - lower), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    enum Springs {
        /// Growing out of the notch: a visible overshoot, like the Dynamic Island.
        static let expand = Animation.spring(response: 0.42, dampingFraction: 0.74)
        /// Shrinking back: settles without much bounce so it doesn't look like it's growing again.
        static let collapse = Animation.spring(response: 0.36, dampingFraction: 0.88)
        /// The notch gulping open as it swallows a window: loose and wobbly.
        static let gulp = Animation.spring(response: 0.5, dampingFraction: 0.55)
        /// Following the pointer during a drag: tight enough to feel attached, soft enough to
        /// smooth out uneven event timing.
        static let track = Animation.interactiveSpring(response: 0.15, dampingFraction: 0.86)
        /// The drop landing as the notch opens: a brief sideways swell that settles out.
        static let splash = Animation.spring(response: 0.5, dampingFraction: 0.5)
        static let content = Animation.spring(response: 0.38, dampingFraction: 0.86)

        static let windowFling = Spring(response: 0.55, dampingRatio: 0.78)

        /// Springs a released pull back to rest, starting at the pointer's release velocity.
        /// `displacement` and `velocity` share a sign convention; velocity is in points per second.
        static func snapBack(displacement: CGFloat, velocity: CGFloat) -> Animation {
            let spring = Spring(response: 0.5, dampingRatio: 0.5)
            guard abs(displacement) > 1 else { return .spring(spring) }
            // SwiftUI measures initial velocity in units of the distance being animated.
            let relative = -velocity / displacement
            return .interpolatingSpring(spring, initialVelocity: min(max(relative, -30), 30))
        }
    }
}

/// Pointer velocity from the most recent samples, in points per second (AppKit screen coordinates).
struct VelocityTracker {
    private var samples: [(time: TimeInterval, point: CGPoint)] = []
    private let sampleWindow: TimeInterval = 0.08

    mutating func reset() {
        samples.removeAll()
    }

    mutating func add(_ point: CGPoint, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        samples.append((time, point))
        samples.removeAll { time - $0.time > 0.2 }
    }

    /// Zero if the pointer has been still for longer than the sample window.
    func velocity(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> CGVector {
        let recent = samples.filter { now - $0.time <= sampleWindow }
        guard let first = recent.first, let last = recent.last else { return .zero }
        let elapsed = last.time - first.time
        guard elapsed > 0.008 else { return .zero }
        return CGVector(
            dx: (last.point.x - first.point.x) / elapsed,
            dy: (last.point.y - first.point.y) / elapsed
        )
    }
}

extension CGVector {
    var magnitude: CGFloat {
        hypot(dx, dy)
    }
}
