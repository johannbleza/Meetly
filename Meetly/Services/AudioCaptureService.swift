import AVFoundation
import Foundation

@MainActor
final class AudioCaptureService {
    private let microphoneCapture = MicrophoneCapture()
    private let systemAudioCapture = SystemAudioCapture()

    var onMicBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onSystemBuffer: ((AVAudioPCMBuffer) -> Void)?

    private(set) var isSystemAudioRunning = false

    /// Starts microphone capture only. System/meeting audio is opt-in via `enableSystemAudioViaPicker()`.
    func start() async throws -> String? {
        wireCaptureCallbacks()
        try microphoneCapture.start()
        isSystemAudioRunning = false
        return nil
    }

    /// Presents the macOS content picker to capture meeting audio from the selected display.
    func enableSystemAudioViaPicker() async -> String? {
        wireCaptureCallbacks()
        return await startSystemAudio(forcePicker: true)
    }

    private func wireCaptureCallbacks() {
        microphoneCapture.onBuffer = { [weak self] buffer in
            Task { @MainActor in
                self?.onMicBuffer?(buffer)
            }
        }

        systemAudioCapture.onBuffer = { [weak self] buffer in
            Task { @MainActor in
                self?.onSystemBuffer?(buffer)
            }
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

    func stop() async {
        microphoneCapture.stop()
        await systemAudioCapture.stop()
        isSystemAudioRunning = false
    }
}
