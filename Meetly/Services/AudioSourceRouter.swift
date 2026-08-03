import AVFoundation
import Foundation

final class AudioSourceRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var _isSystemAudioEnabled = false

    var isSystemAudioEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isSystemAudioEnabled
        }
        set {
            lock.lock()
            _isSystemAudioEnabled = newValue
            lock.unlock()
        }
    }

    var onMicBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onSystemBuffer: ((AVAudioPCMBuffer) -> Void)?

    func reset() {
        isSystemAudioEnabled = false
    }

    /// Safe to call from capture threads.
    func processMicBuffer(_ buffer: AVAudioPCMBuffer) {
        onMicBuffer?(buffer)
    }

    /// Safe to call from capture threads.
    func processSystemBuffer(_ buffer: AVAudioPCMBuffer) {
        onSystemBuffer?(buffer)
    }
}
