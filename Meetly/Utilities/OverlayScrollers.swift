import AppKit
import SwiftUI

extension View {
    /// Forces the enclosing `ScrollView` to use overlay scrollers, so content keeps its full width
    /// when "Show scroll bars: Always" (or a connected mouse) would otherwise give the scroller its own
    /// gutter and shift the layout left whenever the content becomes scrollable.
    /// Apply it to the content *inside* the `ScrollView`.
    func overlayScrollers() -> some View {
        background(OverlayScrollersView())
    }
}

private struct OverlayScrollersView: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ nsView: ProbeView, context: Context) { nsView.apply() }

    final class ProbeView: NSView {
        private var styleObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            guard styleObserver == nil, window != nil else { return }
            // AppKit resets every scroll view to the preferred style when the system setting changes.
            styleObserver = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async { self?.apply() }
            }
        }

        func apply() {
            guard let scrollView = enclosingScrollView, scrollView.scrollerStyle != .overlay else { return }
            scrollView.scrollerStyle = .overlay
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit {
            if let styleObserver { NotificationCenter.default.removeObserver(styleObserver) }
        }
    }
}
