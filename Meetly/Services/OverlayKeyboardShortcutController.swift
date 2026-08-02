import AppKit
import Carbon.HIToolbox

private enum OverlayHotKey {
    static let signature: OSType = OSType(0x4D_4C_59_4F) // "MLYO"
    static let id: UInt32 = 1
}

@MainActor
final class OverlayKeyboardShortcutController {
    static let shared = OverlayKeyboardShortcutController()
    private static weak var hotKeyTarget: OverlayKeyboardShortcutController?

    private weak var sessionManager: SessionManager?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private init() {}

    func configure(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        Self.hotKeyTarget = self
        registerHotKeyIfNeeded()
    }

    private func registerHotKeyIfNeeded() {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyEventHandler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        guard installStatus == noErr else { return }

        let hotKeyID = EventHotKeyID(signature: OverlayHotKey.signature, id: OverlayHotKey.id)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_Backslash),
            UInt32(cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private static let hotKeyEventHandler: EventHandlerUPP = { _, event, _ -> OSStatus in
        guard let event else { return OSStatus(eventNotHandledErr) }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr,
              hotKeyID.signature == OverlayHotKey.signature,
              hotKeyID.id == OverlayHotKey.id else {
            return OSStatus(eventNotHandledErr)
        }

        Task { @MainActor in
            OverlayKeyboardShortcutController.hotKeyTarget?.sessionManager?.handleOverlayShortcut()
        }

        return noErr
    }
}
