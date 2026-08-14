import AVFoundation
import Foundation

nonisolated final class AudioSourceRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var _isSystemAudioEnabled = false
    private var _isEchoSuppressionEnabled = true
    private let echoGate = MicEchoGate()

    var isSystemAudioEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isSystemAudioEnabled
        }
        set {
            lock.lock()
            let wasEnabled = _isSystemAudioEnabled
            _isSystemAudioEnabled = newValue
            lock.unlock()
            if wasEnabled, !newValue {
                echoGate.reset()
            }
        }
    }

    var isEchoSuppressionEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isEchoSuppressionEnabled
        }
        set {
            lock.lock()
            _isEchoSuppressionEnabled = newValue
            lock.unlock()
        }
    }

    var onMicBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onSystemBuffer: ((AVAudioPCMBuffer) -> Void)?

    func reset() {
        isSystemAudioEnabled = false
        echoGate.reset()
    }

    /// Safe to call from capture threads.
    func processMicBuffer(_ buffer: AVAudioPCMBuffer) {
        if isSystemAudioEnabled,
           isEchoSuppressionEnabled,
           echoGate.shouldSuppressMic(buffer) {
            return
        }
        onMicBuffer?(buffer)
    }

    /// Safe to call from capture threads.
    func processSystemBuffer(_ buffer: AVAudioPCMBuffer) {
        echoGate.observeSystem(buffer)
        onSystemBuffer?(buffer)
    }
}
