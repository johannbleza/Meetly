import AVFoundation
import Foundation

nonisolated final class AudioSourceRouter: @unchecked Sendable {
    /// Matches the level `WhisperSegmenter` treats as speech.
    private static let systemSpeechThreshold: Float = 0.008

    private let lock = NSLock()
    private var _isSystemAudioEnabled = false
    private var _lastSystemSpeechUptime: TimeInterval?

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

    /// When meeting audio was last audible, on the `systemUptime` clock.
    /// Known immediately, while the transcript of that audio can lag by seconds.
    var lastSystemSpeechUptime: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return _isSystemAudioEnabled ? _lastSystemSpeechUptime : nil
    }

    var onMicBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onSystemBuffer: ((AVAudioPCMBuffer) -> Void)?

    func reset() {
        lock.lock()
        _isSystemAudioEnabled = false
        _lastSystemSpeechUptime = nil
        lock.unlock()
    }

    /// Safe to call from capture threads.
    func processMicBuffer(_ buffer: AVAudioPCMBuffer) {
        onMicBuffer?(buffer)
    }

    /// Safe to call from capture threads.
    func processSystemBuffer(_ buffer: AVAudioPCMBuffer) {
        if AudioFormatConverter.rmsEnergy(of: buffer) >= Self.systemSpeechThreshold {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            _lastSystemSpeechUptime = now
            lock.unlock()
        }
        onSystemBuffer?(buffer)
    }
}
