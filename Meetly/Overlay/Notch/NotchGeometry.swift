import AppKit

/// Where the notch is, in screen coordinates. Screens without a camera housing get a
/// virtual notch of the same proportions drawn at the top center.
struct NotchMetrics: Equatable {
    let screenFrame: CGRect
    let notchSize: CGSize
    let hasHardwareNotch: Bool

    /// The panel is a fixed transparent canvas: big enough for the tallest notch state plus a
    /// pull, so it never has to resize. Only the drawn shape changes size.
    static let canvasSize = CGSize(width: 680, height: 820)

    var centerX: CGFloat {
        screenFrame.midX
    }

    var canvasFrame: CGRect {
        CGRect(
            x: (centerX - Self.canvasSize.width / 2).rounded(),
            y: screenFrame.maxY - Self.canvasSize.height,
            width: Self.canvasSize.width,
            height: Self.canvasSize.height
        )
    }

    /// The bottom center of the notch, which the floating overlay docks into.
    var dockPoint: CGPoint {
        CGPoint(x: centerX, y: screenFrame.maxY - notchSize.height)
    }

    /// The MacBook's real notch whenever its display is connected, even when another display
    /// holds the menu bar; otherwise a virtual notch on the menu-bar screen.
    @MainActor
    static func current() -> NotchMetrics? {
        guard let screen = screen() else { return nil }
        return metrics(for: screen)
    }

    @MainActor
    static func screen() -> NSScreen? {
        NSScreen.screens.first(where: { metrics(for: $0).hasHardwareNotch }) ?? NSScreen.screens.first
    }

    /// The display the user is working on: the one under the pointer.
    @MainActor
    static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? screen()
    }

    @MainActor
    static func metrics(for screen: NSScreen) -> NotchMetrics {
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           screen.safeAreaInsets.top > 0 {
            // The housing is always centered; its width is what the two menu-bar areas leave.
            let width = screen.frame.width - left.width - right.width
            if width > 40 {
                return NotchMetrics(
                    screenFrame: screen.frame,
                    notchSize: CGSize(width: width, height: screen.safeAreaInsets.top),
                    hasHardwareNotch: true
                )
            }
        }

        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let height = min(max(menuBarHeight, 24), 38)
        return NotchMetrics(
            screenFrame: screen.frame,
            notchSize: CGSize(width: 180, height: height),
            hasHardwareNotch: false
        )
    }
}
