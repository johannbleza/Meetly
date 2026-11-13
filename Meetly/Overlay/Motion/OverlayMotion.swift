import SwiftUI

/// Visual state the floating overlay animates through while it drops out of the notch or
/// docks back into it. The window moves separately (`WindowSpringAnimator`); this only
/// changes how the panel inside it looks.
///
/// The panel is masked by a liquid outline that is either a drop of notch ink (the bead that
/// tore off the notch) or the full panel. Separate axes let it splat open like liquid.
@MainActor
@Observable
final class OverlayMotion {
    /// 0 a drop, 1 the full panel width. Overshoots past 1 while it splats.
    var bloomX: CGFloat = 1
    /// 0 a drop, 1 the full panel height.
    var bloomY: CGFloat = 1
    /// Shape of the drop: positive is a falling teardrop (narrow, tall), negative a splat.
    var dropStretch: CGFloat = 0
    /// Size of the drop; 0 once the notch has swallowed it.
    var dropScale: CGFloat = 1
    /// Black wash over the panel, so the drop reads as notch ink until it opens.
    var ink: Double = 0
    var opacity: Double = 1
    /// 0 far from the notch, 1 close enough that releasing docks it.
    var dockReadiness: CGFloat = 0

    func reset() {
        bloomX = 1
        bloomY = 1
        dropStretch = 0
        dropScale = 1
        ink = 0
        opacity = 1
        dockReadiness = 0
    }

    /// The overlay as it leaves the notch: the drop of notch ink that tore off, `radius` big.
    func setDrop(radius: CGFloat, stretch: CGFloat = 0) {
        bloomX = 0
        bloomY = 0
        dropStretch = stretch
        dropScale = radius / LiquidDrop.radius
        ink = 1
        opacity = 1
        dockReadiness = 0
    }

    /// The drop lands: it squashes flat for an instant, then spreads into the panel with a
    /// wobble while the ink clears to show the overlay.
    func splat() {
        withAnimation(.spring(response: 0.14, dampingFraction: 0.9)) {
            dropStretch = -1
        }
        withAnimation(OverlayPhysics.Springs.splatWidth) {
            bloomX = 1
        }
        withAnimation(OverlayPhysics.Springs.splatHeight.delay(0.03)) {
            bloomY = 1
        }
        withAnimation(.easeOut(duration: 0.3).delay(0.12)) {
            ink = 0
        }
    }

    /// Draws the panel back up into a drop, as it heads for the notch.
    func bead() {
        withAnimation(OverlayPhysics.Springs.bead) {
            bloomX = 0
            bloomY = 0
            dropStretch = 0
            dropScale = 1
            dockReadiness = 0
        }
        withAnimation(.easeIn(duration: 0.14)) {
            ink = 1
        }
    }
}

/// A rounded rectangle that is a drop of `LiquidDrop.radius` at bloom 0 and the panel at
/// bloom 1, anchored at the top center (where the notch is). At bloom 1 it sits just outside
/// the panel so it never trims the panel's own corners.
struct OverlayDropShape: Shape {
    var bloomX: CGFloat
    var bloomY: CGFloat
    var dropStretch: CGFloat
    var dropScale: CGFloat
    var cornerRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(bloomX, bloomY), AnimatablePair(dropStretch, dropScale)) }
        set {
            bloomX = newValue.first.first
            bloomY = newValue.first.second
            dropStretch = newValue.second.first
            dropScale = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let full = rect.insetBy(dx: -2, dy: -2)
        let scale = max(dropScale, 0)
        let stretch = min(max(dropStretch, -1), 1)
        let diameter = LiquidDrop.radius * 2 * scale
        // Stretched or squashed, it keeps its volume.
        let dropWidth = diameter / (1 + 0.28 * stretch)
        let dropHeight = diameter * (1 + 0.28 * stretch)
        let width = max(dropWidth + (full.width - dropWidth) * bloomX, 0)
        let height = max(dropHeight + (full.height - dropHeight) * bloomY, 0)
        let frame = CGRect(x: full.midX - width / 2, y: full.minY, width: width, height: height)
        let round = min(width, height) / 2
        let openness = min(max(min(bloomX, bloomY), 0), 1)
        let radius = min(round + (cornerRadius + 2 - round) * openness, round)
        return RoundedRectangle(cornerRadius: radius, style: .circular).path(in: frame)
    }
}

private struct OverlayMotionEffect: ViewModifier {
    let motion: OverlayMotion?

    func body(content: Content) -> some View {
        if let motion {
            content
                .scaleEffect(1 - 0.03 * motion.dockReadiness, anchor: .top)
                .opacity(motion.opacity)
        } else {
            content
        }
    }
}

extension View {
    /// Applies the floating overlay's dock motion to the whole canvas.
    func overlayMotion(_ motion: OverlayMotion?) -> some View {
        modifier(OverlayMotionEffect(motion: motion))
    }

    /// Masks the panel to the drop outline and draws the ink and dock highlight over it.
    func overlayMotionChrome(_ motion: OverlayMotion?, cornerRadius: CGFloat = OverlayGlassStyle.cornerRadius) -> some View {
        let shape = OverlayDropShape(
            bloomX: motion?.bloomX ?? 1,
            bloomY: motion?.bloomY ?? 1,
            dropStretch: motion?.dropStretch ?? 0,
            dropScale: motion?.dropScale ?? 1,
            cornerRadius: cornerRadius
        )
        return clipShape(shape)
            .overlay {
                if let motion {
                    ZStack {
                        // Not clipped to the panel: a splat can spill past its edges for a moment.
                        shape.fill(.black.opacity(motion.ink))
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.55 * motion.dockReadiness), lineWidth: 1.5)
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}
