import SwiftUI

/// The notch silhouette: concave flares where it meets the top edge of the screen, convex
/// bottom corners, and a body that gives a little under a pull.
///
/// The liquid parts of a pull (the drop, its neck, the bridge to the floating overlay) are
/// drawn separately by `NotchLiquidLayer`, which melts them into this shape.
/// Every parameter is animatable, so springs move the outline itself, not just its frame.
/// The path may extend past `rect` (flares to the sides, the pulled body below).
struct NotchShape: Shape {
    var flare: CGFloat = 8
    var bottomRadius: CGFloat = 12
    var stretch: CGFloat = 0
    var sway: CGFloat = 0
    var squeeze: CGFloat = 0

    var animatableData: AnimatablePair<
        AnimatablePair<CGFloat, CGFloat>,
        AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>
    > {
        get {
            AnimatablePair(
                AnimatablePair(flare, bottomRadius),
                AnimatablePair(AnimatablePair(stretch, sway), squeeze)
            )
        }
        set {
            flare = newValue.first.first
            bottomRadius = newValue.first.second
            stretch = newValue.second.first.first
            sway = newValue.second.first.second
            squeeze = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = rect.minY
        let width = max(rect.width, 1)
        let gap = max(stretch, 0)
        let squash = max(min(stretch, 0), -rect.height * 0.35)
        let bottom = rect.maxY + gap + squash
        // Pulled, the body narrows a little toward the bottom, like liquid hanging.
        let inset = min(gap * 0.3, 8)
        let sideLeft = rect.minX + inset + sway
        let sideRight = rect.maxX - inset + sway
        let squeeze = min(max(self.squeeze, -16), width / 4)
        let bottomLeft = sideLeft + squeeze
        let bottomRight = sideRight - squeeze
        let flare = min(max(self.flare, 0), (bottom - top) / 3)
        let radius = min(max(bottomRadius, 0), (bottomRight - bottomLeft) / 2, (bottom - top) / 2)
        let sideTop = top + flare
        let kappa: CGFloat = 0.5523

        var path = Path()
        path.move(to: CGPoint(x: rect.minX - flare, y: top))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: sideTop),
            control: CGPoint(x: rect.minX, y: top)
        )
        // The sides lean with the sway, curving from the fixed top to the moved bottom.
        let lean = (bottom - radius - sideTop) * 0.5
        path.addCurve(
            to: CGPoint(x: bottomLeft, y: bottom - radius),
            control1: CGPoint(x: rect.minX, y: sideTop + lean),
            control2: CGPoint(x: sideLeft, y: bottom - radius - lean * 0.5)
        )
        path.addCurve(
            to: CGPoint(x: bottomLeft + radius, y: bottom),
            control1: CGPoint(x: bottomLeft, y: bottom - radius + radius * kappa),
            control2: CGPoint(x: bottomLeft + radius - radius * kappa, y: bottom)
        )
        path.addLine(to: CGPoint(x: bottomRight - radius, y: bottom))
        path.addCurve(
            to: CGPoint(x: bottomRight, y: bottom - radius),
            control1: CGPoint(x: bottomRight - radius + radius * kappa, y: bottom),
            control2: CGPoint(x: bottomRight, y: bottom - radius + radius * kappa)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: sideTop),
            control1: CGPoint(x: sideRight, y: bottom - radius - lean * 0.5),
            control2: CGPoint(x: rect.maxX, y: sideTop + lean)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX + flare, y: top),
            control: CGPoint(x: rect.maxX, y: top)
        )
        path.closeSubpath()
        return path
    }
}
