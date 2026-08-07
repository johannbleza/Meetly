import AVFoundation
import Foundation

/// Routes mic vs system-audio buffers into transcription.
///
/// When meeting audio is enabled, quiet speaker bleed into the mic is dropped so
/// remote voices aren't labeled "You". Your own speech still passes when the mic
/// is clearly louder than system audio.
final class AudioSourceRouter: @unchecked Sendable {
    /// Minimum RMS to treat system audio as active.
    static let systemSilenceThreshold: Float = 0.005
    /// Minimum RMS for mic speech. Raised above typical speaker bleed levels.
    static let micSpeechThreshold: Float = 0.025
    /// When system audio is active, mic must be this many times louder to pass.
    static let micDominanceRatio: Float = 2.5

    private let lock = NSLock()
    private var _isSystemAudioEnabled = false
    private var recentSystemRMS: Float = 0

    var isSystemAudioEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isSystemAudioEnabled
        }
        set {
            lock.lock()
            _isSystemAudioEnabled = newValue
            if !newValue {
                recentSystemRMS = 0
            }
            lock.unlock()
        }
    }

    var onMicBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onSystemBuffer: ((AVAudioPCMBuffer) -> Void)?

    func reset() {
        lock.lock()
        _isSystemAudioEnabled = false
        recentSystemRMS = 0
        lock.unlock()
    }

    /// Safe to call from capture threads.
    func processMicBuffer(_ buffer: AVAudioPCMBuffer) {
        let micRMS = AudioFormatConverter.rmsEnergy(of: buffer)

        lock.lock()
        let systemEnabled = _isSystemAudioEnabled
        let systemRMS = recentSystemRMS
        lock.unlock()

        guard systemEnabled else {
            // Mic-only: no gating — soft speech should still transcribe.
            onMicBuffer?(buffer)
            return
        }

        guard shouldFeedMic(micRMS: micRMS, systemRMS: systemRMS) else { return }
        onMicBuffer?(buffer)
    }

    /// Safe to call from capture threads.
    func processSystemBuffer(_ buffer: AVAudioPCMBuffer) {
        let rms = AudioFormatConverter.rmsEnergy(of: buffer)

        lock.lock()
        // Light EMA so brief dips between words don't immediately reopen the mic.
        recentSystemRMS = recentSystemRMS * 0.7 + rms * 0.3
        lock.unlock()

        onSystemBuffer?(buffer)
    }

    private func shouldFeedMic(micRMS: Float, systemRMS: Float) -> Bool {
        guard micRMS >= Self.micSpeechThreshold else { return false }

        let systemActive = systemRMS >= Self.systemSilenceThreshold
        if systemActive {
            return micRMS > systemRMS * Self.micDominanceRatio
        }

        return true
    }
}
