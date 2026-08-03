import AppKit
import SwiftUI

/// Transparent region that moves the floating overlay window on drag.
/// Used because `isMovableByWindowBackground` is off so the resize handle can work.
final class OverlayWindowDragRegionView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct OverlayWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> OverlayWindowDragRegionView {
        OverlayWindowDragRegionView()
    }

    func updateNSView(_ nsView: OverlayWindowDragRegionView, context: Context) {}
}
