import AppKit

/// Excludes Meetly windows from screen sharing and capture.
///
/// Sets `NSWindow.sharingType` to `.none`, which hides window content from
/// ScreenCaptureKit streams, legacy capture APIs, and most conferencing apps.
enum ScreenShareExclusion {
    static func apply(to window: NSWindow) {
        window.sharingType = .none
    }

    static func applyToAllWindows() {
        for window in NSApplication.shared.windows {
            apply(to: window)
        }
    }
}
