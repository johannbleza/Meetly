import AppKit

@MainActor
final class MainWindowController {
    static let shared = MainWindowController()

    private weak var mainWindow: NSWindow?
    private var windowDelegate: MainWindowCloseDelegate?

    private init() {}

    var isMainWindowVisible: Bool {
        mainWindow?.isVisible ?? false
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
        mainWindow?.orderOut(nil)
    }

    func showMainWindow() {
        mainWindow?.makeKeyAndOrderFront(nil)
        if let mainWindow {
            ScreenShareExclusion.apply(to: mainWindow)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private final class MainWindowCloseDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
