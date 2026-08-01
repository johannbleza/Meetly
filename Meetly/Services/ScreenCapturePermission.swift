import AppKit
import Foundation
import ScreenCaptureKit

enum ScreenCapturePermission {
    static var executablePath: String {
        Bundle.main.bundleURL.path
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
        Meetly transcribes your microphone by default — no screen recording permission needed.

        To also capture audio from Zoom, Teams, or other apps, click "Capture Meeting Audio" \
        during a meeting. macOS groups this under Screen & System Audio Recording even though \
        Meetly only reads audio, not your screen.
        """
    }

    static func friendlyMessage(for error: Error) -> String {
        if isPermissionError(error) {
            return pickerCancelledMessage
        }
        return error.localizedDescription
    }
}
