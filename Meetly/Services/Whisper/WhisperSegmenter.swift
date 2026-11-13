import Foundation

/// Splits a continuous 16 kHz mono stream into utterances for Whisper, which decodes
/// fixed windows rather than streaming. Pure logic with no audio or threading concerns.
nonisolated struct WhisperSegmenter {
    struct Configuration {
        var sampleRate = 16_000
        /// Frame RMS at or above this counts as speech.
        var speechThreshold: Float = 0.008
        var frameDuration = 0.03
        /// Silence that ends an utterance.
        var endOfSpeechSilence = 0.7
        /// Long speech is cut at this length, keeping each decode well inside Whisper's 30 s window.
        var maxSegmentDuration = 12.0
        /// A forced cut lands on the quietest frame within this much of the limit.
        var cutSearchDuration = 2.0
        /// Utterances with less speech than this are discarded as noise.
        var minimumSpeechDuration = 0.25
        /// Audio kept ahead of detected speech so first syllables aren't clipped.
        var preRollDuration = 0.3
        /// New audio required before re-decoding for a live caption.
        var partialInterval = 1.0
    }

    enum Work: Equatable {
        case partial([Float])
        case final([Float])
    }

    private let configuration: Configuration
    private let frameLength: Int
    private var samples: [Float] = []
    private var scannedSamples = 0
    private var speechSamples = 0
    private var trailingSilenceSamples = 0
    private var samplesAtLastPartial = 0

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        frameLength = Int(Double(configuration.sampleRate) * configuration.frameDuration)
    }

    mutating func append(_ newSamples: [Float]) {
        samples.append(contentsOf: newSamples)
        scanNewFrames()
    }

    /// The next decode to run, if any.
    /// - Parameter inputStalled: audio stopped arriving (muted mic, silent system stream),
    ///   so the current utterance ends even though no silence was measured.
    mutating func nextWork(inputStalled: Bool) -> Work? {
        guard speechSamples > 0 else {
            trimToPreRoll()
            return nil
        }

        if trailingSilenceSamples >= seconds(configuration.endOfSpeechSilence) || inputStalled {
            return finishUtterance()
        }

        if samples.count >= seconds(configuration.maxSegmentDuration) {
            return cutLongUtterance()
        }

        let hasEnoughSpeech = speechSamples >= seconds(configuration.minimumSpeechDuration)
        if hasEnoughSpeech, samples.count - samplesAtLastPartial >= seconds(configuration.partialInterval) {
            samplesAtLastPartial = samples.count
            return .partial(samples)
        }
        return nil
    }

    /// Drains whatever speech remains, for when the channel stops.
    mutating func flush() -> [Float]? {
        if case .final(let remaining) = nextWork(inputStalled: true) {
            return remaining
        }
        return nil
    }

    private func seconds(_ duration: Double) -> Int {
        Int(duration * Double(configuration.sampleRate))
    }

    private mutating func finishUtterance() -> Work? {
        let utterance = samples
        let hasEnoughSpeech = speechSamples >= seconds(configuration.minimumSpeechDuration)
        reset(keeping: [])
        return hasEnoughSpeech ? .final(utterance) : nil
    }

    private mutating func cutLongUtterance() -> Work {
        let limit = seconds(configuration.maxSegmentDuration)
        let searchStart = max(0, limit - seconds(configuration.cutSearchDuration))
        let cut = quietestFrameStart(in: searchStart..<limit)
        let utterance = Array(samples[..<cut])
        reset(keeping: Array(samples[cut...]))
        return .final(utterance)
    }

    private func quietestFrameStart(in range: Range<Int>) -> Int {
        var bestStart = range.upperBound
        var bestEnergy = Float.greatestFiniteMagnitude
        var start = range.lowerBound
        while start + frameLength <= range.upperBound {
            let energy = rms(from: start)
            if energy < bestEnergy {
                bestEnergy = energy
                bestStart = start
            }
            start += frameLength
        }
        return bestStart
    }

    private mutating func reset(keeping remainder: [Float]) {
        samples = remainder
        scannedSamples = 0
        speechSamples = 0
        trailingSilenceSamples = 0
        samplesAtLastPartial = 0
        scanNewFrames()
    }

    private mutating func scanNewFrames() {
        while scannedSamples + frameLength <= samples.count {
            if rms(from: scannedSamples) >= configuration.speechThreshold {
                speechSamples += frameLength
                trailingSilenceSamples = 0
            } else {
                trailingSilenceSamples += frameLength
            }
            scannedSamples += frameLength
        }
    }

    private mutating func trimToPreRoll() {
        let excess = samples.count - seconds(configuration.preRollDuration)
        guard excess > 0 else { return }
        // Only drop scanned audio, whole frames at a time, so the scan stays frame-aligned.
        let removable = min(excess, scannedSamples) / frameLength * frameLength
        guard removable > 0 else { return }
        samples.removeFirst(removable)
        scannedSamples -= removable
        samplesAtLastPartial = 0
        trailingSilenceSamples = 0
    }

    private func rms(from start: Int) -> Float {
        var sum: Float = 0
        for index in start..<(start + frameLength) {
            sum += samples[index] * samples[index]
        }
        return (sum / Float(frameLength)).squareRoot()
    }
}
