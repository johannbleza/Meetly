import AppKit

@MainActor
final class MainWindowController {
    static let shared = MainWindowController()
    /// The main window's scene (`MeetlyApp`).
    static let windowID = "main"

    /// Opens a new main window. Handed over by the menu bar label, the one view that exists when
    /// no window does (`MenuBarIconLabel`).
    var openWindow: (@MainActor () -> Void)?

    private weak var mainWindow: NSWindow?
    private var windowDelegate: MainWindowCloseDelegate?
    private var moveObserver: NSObjectProtocol?
    private var dragMonitor: Any?
    /// The window is being dragged by its title bar (the WindowServer moves it).
    private var isDraggingWindow = false
    /// Asked SwiftUI for a window that hasn't registered yet: don't ask for a second one.
    private var isOpeningWindow = false

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
        let isNewWindow = mainWindow !== window
        mainWindow = window
        isOpeningWindow = false
        ScreenShareExclusion.apply(to: window)

        let delegate = MainWindowCloseDelegate()
        windowDelegate = delegate
        window.delegate = delegate
        if isNewWindow {
            trackDrags(of: window)
        }
    }

    /// Launched at login: Meets starts in the menu bar. AppKit opens no new window for a login
    /// launch, but it restores the ones left open at logout ("Reopen windows when logging back
    /// in"), before `applicationDidFinishLaunching` and before they register here. They go back
    /// out at once and without the close animation, so the restored window is never seen.
    func startHidden() {
        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) && !(window is NSPanel) {
            let animation = window.animationBehavior
            window.animationBehavior = .none
            window.orderOut(nil)
            window.animationBehavior = animation
        }
    }

    func hideMainWindow() {
        let overlay = OverlayPanelController.shared
        overlay.endWindowPull()
        // Hidden in the middle of a genie: skip the rest of it.
        overlay.windowGenie.cancel(hiding: true)
        mainWindow?.orderOut(nil)
    }

    func showMainWindow() {
        let overlay = OverlayPanelController.shared
        // It was dragged into the notch: it pours back out of it.
        if overlay.releaseMainWindowFromNotch() { return }
        overlay.endWindowPull()
        // Opened in the middle of a genie (e.g. from the menu bar): skip the rest of it.
        overlay.windowGenie.cancel()
        guard let mainWindow else {
            // There's none yet: a login launch makes none, and a restore can come back without it.
            if !isOpeningWindow, let openWindow {
                isOpeningWindow = true
                openWindow()
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        mainWindow.makeKeyAndOrderFront(nil)
        // The genie always takes its warp off, but a window left warped would be invisible.
        WindowWarp.clear(mainWindow)
        ScreenShareExclusion.apply(to: mainWindow)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

extension MainWindowController {
    /// Follows title-bar drags of `window`, so the notch can reach for it when it's carried up
    /// to it and take it when it's let go there (`OverlayPanelController.mainWindowDragMoved`).
    /// The WindowServer moves the window, but the app still gets `willMove` as it starts (never
    /// for a move made in code) and every dragged event, and the mouse-up.
    private func trackDrags(of window: NSWindow) {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        isDraggingWindow = false
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
                self?.isDraggingWindow = true
            }
        }
        guard dragMonitor == nil else { return }
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.windowDragEvent(event)
            }
            return event
        }
    }

    private func windowDragEvent(_ event: NSEvent) {
        guard isDraggingWindow else { return }
        let overlay = OverlayPanelController.shared
        if event.type == .leftMouseUp || NSEvent.pressedMouseButtons & 1 == 0 {
            isDraggingWindow = false
            overlay.mainWindowDragEnded()
            return
        }
        guard let mainWindow, event.window === mainWindow else { return }
        overlay.mainWindowDragMoved()
    }
}

private final class MainWindowCloseDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
