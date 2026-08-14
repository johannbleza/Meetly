import AVFoundation
import Foundation

/// Drops microphone buffers that are likely loudspeaker playback of meeting audio.
///
/// Capture threads only — no MainActor hops. Uses per-source noise floors and
/// delayed energy-envelope correlation so the user's own speech still passes
/// during double-talk.
nonisolated final class MicEchoGate: @unchecked Sendable {
    private struct Sample {
        let time: TimeInterval
        let rms: Float
    }

    private let lock = NSLock()
    private var systemSamples: [Sample] = []
    private var micSamples: [Sample] = []
    private var systemNoiseFloor: Float = 0.004
    private var micNoiseFloor: Float = 0.006
    private var lastSystemActiveAt: TimeInterval = 0

    private let historySeconds: TimeInterval = 0.7
    private let micHistorySeconds: TimeInterval = 0.35
    private let maxEchoDelay: TimeInterval = 0.28
    private let hangover: TimeInterval = 0.3
    private let correlationThreshold: Float = 0.65
    private let minPairs = 6

    func reset() {
        lock.lock()
        systemSamples.removeAll(keepingCapacity: true)
        micSamples.removeAll(keepingCapacity: true)
        systemNoiseFloor = 0.004
        micNoiseFloor = 0.006
        lastSystemActiveAt = 0
        lock.unlock()
    }

    func observeSystem(_ buffer: AVAudioPCMBuffer) {
        let rms = AudioFormatConverter.rmsEnergy(of: buffer)
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }

        updateNoiseFloor(&systemNoiseFloor, rms: rms)
        systemSamples.append(Sample(time: now, rms: rms))
        prune(now: now)
        if rms > systemSpeechThreshold {
            lastSystemActiveAt = now
        }
    }

    /// Returns true when the mic buffer is likely speaker bleed and should not be transcribed.
    func shouldSuppressMic(_ buffer: AVAudioPCMBuffer) -> Bool {
        let rms = AudioFormatConverter.rmsEnergy(of: buffer)
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }

        updateNoiseFloor(&micNoiseFloor, rms: rms)
        micSamples.append(Sample(time: now, rms: rms))
        prune(now: now)

        let systemActive = rmsSystemCurrent > systemSpeechThreshold
            || (now - lastSystemActiveAt) < hangover
        guard systemActive else { return false }

        if rms < micSpeechThreshold {
            return true
        }

        if let correlation = maxEnvelopeCorrelation(), correlation >= correlationThreshold {
            return true
        }

        return false
    }

    private var systemSpeechThreshold: Float {
        max(0.012, systemNoiseFloor * 4)
    }

    private var micSpeechThreshold: Float {
        max(0.012, micNoiseFloor * 3.5)
    }

    private var rmsSystemCurrent: Float {
        systemSamples.last?.rms ?? 0
    }

    private func updateNoiseFloor(_ floor: inout Float, rms: Float) {
        if rms < floor * 1.5 {
            floor = floor * 0.95 + rms * 0.05
        } else {
            floor = min(floor * 1.002, 0.02)
        }
        floor = max(0.0015, min(floor, 0.02))
    }

    private func prune(now: TimeInterval) {
        let systemCutoff = now - historySeconds
        systemSamples.removeAll { $0.time < systemCutoff }
        let micCutoff = now - micHistorySeconds
        micSamples.removeAll { $0.time < micCutoff }
    }

    private func maxEnvelopeCorrelation() -> Float? {
        guard micSamples.count >= minPairs, systemSamples.count >= minPairs else { return nil }

        var best: Float = -1
        var delay: TimeInterval = 0
        while delay <= maxEchoDelay {
            if let correlation = pearson(delay: delay) {
                best = max(best, correlation)
            }
            delay += 0.02
        }
        return best >= 0 ? best : nil
    }

    private func pearson(delay: TimeInterval) -> Float? {
        var xs: [Float] = []
        var ys: [Float] = []
        xs.reserveCapacity(micSamples.count)
        ys.reserveCapacity(micSamples.count)

        var systemIndex = 0
        for mic in micSamples {
            let target = mic.time - delay
            while systemIndex + 1 < systemSamples.count {
                let currentError = abs(systemSamples[systemIndex].time - target)
                let nextError = abs(systemSamples[systemIndex + 1].time - target)
                if nextError <= currentError {
                    systemIndex += 1
                } else {
                    break
                }
            }
            guard systemIndex < systemSamples.count else { continue }
            let system = systemSamples[systemIndex]
            guard abs(system.time - target) < 0.05 else { continue }
            xs.append(mic.rms)
            ys.append(system.rms)
        }

        guard xs.count >= minPairs else { return nil }
        return Self.pearsonCorrelation(xs, ys)
    }

    private static func pearsonCorrelation(_ x: [Float], _ y: [Float]) -> Float {
        let n = Float(x.count)
        var sumX: Float = 0
        var sumY: Float = 0
        var sumXY: Float = 0
        var sumX2: Float = 0
        var sumY2: Float = 0
        for index in 0..<x.count {
            let xi = x[index]
            let yi = y[index]
            sumX += xi
            sumY += yi
            sumXY += xi * yi
            sumX2 += xi * xi
            sumY2 += yi * yi
        }
        let numerator = n * sumXY - sumX * sumY
        let denominator = sqrt((n * sumX2 - sumX * sumX) * (n * sumY2 - sumY * sumY))
        guard denominator > 1e-8 else { return 0 }
        return numerator / denominator
    }
}
