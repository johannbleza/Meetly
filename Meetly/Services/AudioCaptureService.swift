import AVFoundation
import Foundation

@MainActor
final class AudioCaptureService {
    private final class BufferHandlers: @unchecked Sendable {
        var onMic: ((AVAudioPCMBuffer) -> Void)?
        var onSystem: ((AVAudioPCMBuffer) -> Void)?
    }

    private let microphoneCapture = MicrophoneCapture()
    private let systemAudioCapture = SystemAudioCapture()
    private let handlers = BufferHandlers()

    /// Invoked on capture threads (mic tap / ScreenCaptureKit queue).
    var onMicBuffer: ((AVAudioPCMBuffer) -> Void)? {
        get { handlers.onMic }
        set { handlers.onMic = newValue }
    }

    var onSystemBuffer: ((AVAudioPCMBuffer) -> Void)? {
        get { handlers.onSystem }
        set { handlers.onSystem = newValue }
    }

    private(set) var isSystemAudioRunning = false

    var isMicrophoneMuted: Bool {
        microphoneCapture.isMuted
    }

    func setMicrophoneMuted(_ muted: Bool) {
        microphoneCapture.setMuted(muted)
    }

    /// Starts microphone capture only. System/meeting audio is opt-in via `enableSystemAudioViaPicker()`.
    func start() async throws -> String? {
        wireCaptureCallbacks()
        microphoneCapture.setMuted(false)
        try microphoneCapture.start()
        isSystemAudioRunning = false
        return nil
    }

    /// Presents the macOS content picker to capture meeting audio from the selected display.
    func enableSystemAudioViaPicker() async -> String? {
        wireCaptureCallbacks()
        return await startSystemAudio(forcePicker: true)
    }

    /// Starts meeting-audio capture via the system share picker.
    ///
    /// Always uses `SCContentSharingPicker` instead of programmatic `SCShareableContent`,
    /// which triggers the Screen Recording permission dialog (and Sequoia re-prompts)
    /// even when the user already enabled Meetly in System Settings.
    func startSystemAudioIfPossible() async -> String? {
        wireCaptureCallbacks()
        return await startSystemAudio(forcePicker: true)
    }

    private func wireCaptureCallbacks() {
        let handlers = self.handlers
        microphoneCapture.onBuffer = { buffer in
            handlers.onMic?(buffer)
        }
        systemAudioCapture.onBuffer = { buffer in
            handlers.onSystem?(buffer)
        }
    }

    private func startSystemAudio(forcePicker: Bool = false) async -> String? {
        do {
            if forcePicker {
                try await systemAudioCapture.startViaContentPicker()
            } else {
                try await systemAudioCapture.start()
            }
            isSystemAudioRunning = true
            return nil
        } catch {
            isSystemAudioRunning = false
            return ScreenCapturePermission.friendlyMessage(for: error)
        }
    }

    func pause() async {
        microphoneCapture.stop()
        await systemAudioCapture.stop()
    }

    func resume() async throws -> String? {
        wireCaptureCallbacks()
        try microphoneCapture.start()
        if isSystemAudioRunning {
            // Prefer silent programmatic resume only when TCC is already granted;
            // otherwise the share picker avoids another Screen Recording dialog.
            if ScreenCapturePermission.hasScreenRecordingAccess {
                if await startSystemAudio(forcePicker: false) == nil {
                    return nil
                }
            }
            return await startSystemAudio(forcePicker: true)
        }
        return nil
    }

    func stop() async {
        microphoneCapture.stop()
        microphoneCapture.setMuted(false)
        await systemAudioCapture.stop()
        isSystemAudioRunning = false
    }
}
