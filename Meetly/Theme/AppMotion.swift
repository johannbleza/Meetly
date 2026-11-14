import AppKit
import SwiftUI

/// The main window's springs and slides. Pages and content move across rather than crossfading,
/// so two copies of a page are never drawn over each other.
enum AppMotion {
    /// Opening a meeting, going back and forward.
    static let page = Animation.spring(duration: 0.44, bounce: 0.06)
    /// Meetings ⇄ Archived.
    static let pager = Animation.spring(duration: 0.42, bounce: 0.08)
    /// Detail tabs, list / grid / calendar, calendar months.
    static let content = Animation.spring(duration: 0.38, bounce: 0.06)
    /// The featured card rising into the meeting page and settling back.
    static let hero = Animation.spring(duration: 0.5, bounce: 0.12)
    /// How far the page underneath drifts while another slides over it, as a share of its width.
    static let parallax: CGFloat = 0.3

    /// Nil under Reduce Motion, so the change cuts instead.
    @MainActor
    static func resolved(_ animation: Animation) -> Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : animation
    }

    /// Runs `change` animated once a direction it depends on has been applied. A view being
    /// removed keeps the transition from its last update, so a new direction needs an update of
    /// its own before the change, or the outgoing view would leave the old way.
    @MainActor
    static func afterDirection(changed: Bool, _ animation: Animation, _ change: @escaping () -> Void) {
        let animation = resolved(animation)
        guard changed, animation != nil else {
            withAnimation(animation, change)
            return
        }
        DispatchQueue.main.async { withAnimation(animation, change) }
    }
}

extension AnyTransition {
    /// Slides in from one side and out the other, `distance` points, with no fade.
    static func slide(forward: Bool, distance: CGFloat) -> AnyTransition {
        .asymmetric(
            insertion: .offset(x: forward ? distance : -distance),
            removal: .offset(x: forward ? -distance : distance)
        )
    }
}

/// A soft shadow just outside a page's leading edge. Off screen while the page rests; it shows
/// only while the page slides over the one under it.
struct PageEdgeShadow: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.07)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 18)
                .offset(x: -18)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// The pointing-hand cursor over something clickable: rows, cards and plain-styled buttons,
    /// which otherwise keep the arrow and don't look clickable. Disabled controls keep the arrow.
    func clickableCursor() -> some View {
        modifier(ClickableCursor())
    }
}

private struct ClickableCursor: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.pointerStyle(isEnabled ? .link : nil)
    }
}
