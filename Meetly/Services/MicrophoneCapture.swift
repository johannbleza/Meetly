import AVFoundation
import Foundation

@MainActor
final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var isRunning = false

    /// Read from the audio tap thread; write from the main actor only.
    nonisolated(unsafe) private(set) var isMuted = false

    /// Invoked on the audio tap thread — keep handlers off the main actor.
    nonisolated(unsafe) var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func setMuted(_ muted: Bool) {
        isMuted = muted
    }

    func start() throws {
        guard !isRunning else { return }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, !self.isMuted else { return }
            self.onBuffer?(buffer)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }
}
