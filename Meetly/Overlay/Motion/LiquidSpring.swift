import CoreGraphics

/// A one-dimensional damped spring, stepped by hand once per display frame. `response` is
/// roughly the seconds it takes to arrive; `damping` below 1 overshoots and settles. Same
/// meaning as SwiftUI's `.spring(response:dampingFraction:)`.
///
/// The liquid is simulated rather than animated: every part keeps its own velocity, so a
/// drop retargeted mid-flight carries its momentum, wobbles, and merges the way liquid does.
struct LiquidSpring {
    struct Params {
        var response: Double
        var damping: Double
    }

    var value: Double
    var velocity: Double = 0
    var target: Double

    init(_ value: Double) {
        self.value = value
        target = value
    }

    mutating func snap(_ value: Double) {
        self.value = value
        target = value
        velocity = 0
    }

    /// Semi-implicit Euler: stable for the small substeps the drivers take.
    mutating func step(_ dt: Double, _ params: Params) {
        let omega = 2 * Double.pi / params.response
        let acceleration = -omega * omega * (value - target) - 2 * params.damping * omega * velocity
        velocity += acceleration * dt
        value += velocity * dt
    }

    func isSettled(within distance: Double = 0.3, speed: Double = 4) -> Bool {
        abs(value - target) < distance && abs(velocity) < speed
    }
}

/// Sizes shared by the notch's drop and the floating overlay that starts as it.
enum LiquidDrop {
    /// Radius of the drop a pull draws out of the notch, at full size.
    static let radius: CGFloat = 48
    /// Blur radius of the goo filter: how far apart two shapes can be and still be joined by a
    /// liquid neck (about 1.3 times this), and how round the necks are.
    static let goo: CGFloat = 7
}
