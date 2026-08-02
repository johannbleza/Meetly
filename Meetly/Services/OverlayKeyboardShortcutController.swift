import AppKit

@MainActor
final class OverlayKeyboardShortcutController {
    static let shared = OverlayKeyboardShortcutController()

    private weak var sessionManager: SessionManager?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    private init() {}

    func configure(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        installMonitorsIfNeeded()
    }

    private func installMonitorsIfNeeded() {
        guard localMonitor == nil else { return }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.matchesToggleShortcut(event) else { return event }
            self.sessionManager?.handleOverlayShortcut()
            return nil
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.matchesToggleShortcut(event) else { return }
            Task { @MainActor in
                self.sessionManager?.handleOverlayShortcut()
            }
        }
    }

    private func matchesToggleShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return false }
        return event.charactersIgnoringModifiers == "\\"
    }
}
