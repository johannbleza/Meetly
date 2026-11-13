import AppKit
import SwiftUI

/// Transparent region that moves the floating overlay window on drag.
///
/// Moves the window itself rather than calling `performDrag`, which keeps windows out of the
/// menu bar: the overlay has to be carried up into the notch to dock. It also measures the
/// release velocity so a flick throws the panel.
final class OverlayWindowDragRegionView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    // The panel is rarely key, so cursor rects alone don't fire; a tracking area with
    // `.activeAlways` updates the cursor whatever window is active.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        NSCursor.closedHand.set()
        defer {
            let inside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
            (inside ? NSCursor.openHand : NSCursor.arrow).set()
        }

        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        var tracker = VelocityTracker()
        tracker.add(startMouse)
        var isDragging = false
        let controller = OverlayPanelController.shared

        while true {
            guard let next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else {
                break
            }

            let mouse = NSEvent.mouseLocation
            tracker.add(mouse)

            if next.type == .leftMouseUp {
                if isDragging {
                    controller.floatingDragEnded(velocity: tracker.velocity())
                }
                break
            }

            if !isDragging {
                guard hypot(mouse.x - startMouse.x, mouse.y - startMouse.y) >= 2 else { continue }
                isDragging = true
                controller.floatingDragBegan()
            }
            window.setFrameOrigin(CGPoint(
                x: startOrigin.x + mouse.x - startMouse.x,
                y: startOrigin.y + mouse.y - startMouse.y
            ))
            controller.floatingDragMoved()
        }
    }
}

struct OverlayWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> OverlayWindowDragRegionView {
        OverlayWindowDragRegionView()
    }

    func updateNSView(_ nsView: OverlayWindowDragRegionView, context: Context) {}
}
