import AppKit
import SwiftUI

final class OverlayResizeHandleView: NSView {
    var currentHeight: (() -> CGFloat)?
    var onHeightChange: ((CGFloat) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: OverlayGlassStyle.resizeHandleHeight)
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }

        // Steal the drag from the floating panel's background-move behavior.
        let wasMovable = window.isMovableByWindowBackground
        window.isMovableByWindowBackground = false
        defer { window.isMovableByWindowBackground = wasMovable }

        let startHeight = currentHeight?() ?? OverlayGlassStyle.contentMaxHeightListening
        // Screen coords stay stable even if the window briefly moves.
        let startMouseY = NSEvent.mouseLocation.y

        while true {
            guard let next = window.nextEvent(
                matching: [.leftMouseUp, .leftMouseDragged],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else {
                break
            }

            if next.type == .leftMouseUp {
                break
            }

            let delta = startMouseY - NSEvent.mouseLocation.y
            let nextHeight = OverlayGlassStyle.clampContentHeight(startHeight + delta)
            MainActor.assumeIsolated {
                onHeightChange?(nextHeight)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let pillWidth: CGFloat = 36
        let pillHeight: CGFloat = 4
        let pillRect = NSRect(
            x: (bounds.width - pillWidth) / 2,
            y: (bounds.height - pillHeight) / 2,
            width: pillWidth,
            height: pillHeight
        )
        NSColor.secondaryLabelColor.withAlphaComponent(0.4).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: pillHeight / 2, yRadius: pillHeight / 2).fill()
    }
}

struct OverlayResizeHandle: NSViewRepresentable {
    var currentHeight: () -> CGFloat
    var onHeightChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> OverlayResizeHandleView {
        let view = OverlayResizeHandleView()
        view.toolTip = "Drag to resize overlay height"
        view.currentHeight = currentHeight
        view.onHeightChange = onHeightChange
        return view
    }

    func updateNSView(_ nsView: OverlayResizeHandleView, context: Context) {
        nsView.currentHeight = currentHeight
        nsView.onHeightChange = onHeightChange
    }
}
