import AppKit

@MainActor
final class MainWindowController {
    static let shared = MainWindowController()

    private weak var mainWindow: NSWindow?

    private init() {}

    func register(_ window: NSWindow) {
        guard !(window is NSPanel) else { return }
        mainWindow = window
    }

    func hideMainWindow() {
        mainWindow?.orderOut(nil)
    }

    func showMainWindow() {
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
