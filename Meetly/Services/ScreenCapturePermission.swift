import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum ScreenCapturePermission {
    static var executablePath: String {
        Bundle.main.bundleURL.path
    }

    /// True when Screen Recording TCC is already granted. Does not show a prompt.
    static var hasScreenRecordingAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        if message.contains("declined tcc") || message.contains("tcc") {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == "com.apple.screencapturekit" {
            return true
        }
        if nsError.domain == SCStreamErrorDomain, nsError.code == -3801 {
            return true
        }
        return false
    }

    static func openSystemSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    static var pickerCancelledMessage: String {
        """
        Meeting audio was not enabled. Meetly is still transcribing your microphone.

        Click "Capture Meeting Audio" and choose your display in the macOS picker.
        """
    }

    static var troubleshootingMessage: String {
        """
        Meetly transcribes your microphone by default — no Screen Recording permission needed.

        To also capture Zoom/Teams audio, use "Capture Meeting Audio" (or enable capture by \
        default). Meetly uses the macOS share picker so you choose a display once per meeting \
        without the Screen Recording permission dialog.

        If you previously toggled Meetly in System Settings while running from Xcode, quit the \
        app fully and relaunch after changing the toggle — macOS only applies that change to a \
        new process.
        """
    }

    static func friendlyMessage(for error: Error) -> String {
        if isPermissionError(error) {
            return pickerCancelledMessage
        }
        return error.localizedDescription
    }
}
