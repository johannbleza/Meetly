import SwiftUI

/// Visual state of the floating overlay while it's handled near the notch. The window itself
/// moves on `WindowSpringAnimator` and docks or detaches through the genie
/// (`WindowGenieController`); this only changes how the panel inside it looks.
@MainActor
@Observable
final class OverlayMotion {
    var opacity: Double = 1
    /// 0 far from the notch, 1 close enough that releasing docks it.
    var dockReadiness: CGFloat = 0
    /// The drawn panel's height (the window is a taller transparent canvas), measured by the
    /// view, so the genie funnels only what shows. Nothing draws from it.
    @ObservationIgnored var panelHeight: CGFloat = 0

    func reset() {
        opacity = 1
        dockReadiness = 0
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

    /// Outlines the panel as it's carried close enough to the notch to dock.
    func overlayMotionChrome(_ motion: OverlayMotion?, cornerRadius: CGFloat = OverlayGlassStyle.cornerRadius) -> some View {
        overlay {
            if let motion {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.55 * motion.dockReadiness), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
    }
}
