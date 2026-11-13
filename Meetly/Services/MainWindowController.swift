import AppKit

@MainActor
final class MainWindowController {
    static let shared = MainWindowController()

    private weak var mainWindow: NSWindow?
    private var windowDelegate: MainWindowCloseDelegate?

    private init() {}

    var window: NSWindow? {
        mainWindow
    }

    var isMainWindowVisible: Bool {
        // Sucked into the notch, but not ordered out yet.
        (mainWindow?.isVisible ?? false) && !OverlayPanelController.shared.windowGenie.isHidingWindow
    }

    /// Something the genie can warp: not full screen or minimized.
    var canMorph: Bool {
        guard let mainWindow else { return false }
        return !mainWindow.styleMask.contains(.fullScreen) && !mainWindow.isMiniaturized
    }

    /// Showing right now: on screen, on this Space, and not completely covered.
    var isMainWindowOnScreen: Bool {
        guard let mainWindow, isMainWindowVisible else { return false }
        return mainWindow.isOnActiveSpace && mainWindow.occlusionState.contains(.visible)
    }

    func isMainWindow(_ window: NSWindow?) -> Bool {
        guard let window, let mainWindow else { return false }
        return window === mainWindow
    }

    func register(_ window: NSWindow) {
        guard !(window is NSPanel) else { return }
        mainWindow = window
        ScreenShareExclusion.apply(to: window)

        let delegate = MainWindowCloseDelegate()
        windowDelegate = delegate
        window.delegate = delegate
    }

    func hideMainWindow() {
        // Hidden in the middle of a genie: skip the rest of it.
        OverlayPanelController.shared.windowGenie.cancel(hiding: true)
        mainWindow?.orderOut(nil)
    }

    func showMainWindow() {
        // Opened in the middle of a genie (e.g. from the menu bar): skip the rest of it.
        OverlayPanelController.shared.windowGenie.cancel()
        guard let mainWindow else { return }
        mainWindow.makeKeyAndOrderFront(nil)
        // The genie always takes its warp off, but a window left warped would be invisible.
        WindowWarp.clear(mainWindow)
        ScreenShareExclusion.apply(to: mainWindow)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private final class MainWindowCloseDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
