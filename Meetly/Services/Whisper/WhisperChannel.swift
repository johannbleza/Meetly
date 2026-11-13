import AVFoundation
import Foundation

/// Buffers one audio source and decodes it with Whisper on a background task.
nonisolated final class WhisperChannel: TranscriptionChannel, @unchecked Sendable {
    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private static let pollInterval: Duration = .milliseconds(200)
    /// A gap this long between buffers means the source went quiet (muted mic, silent stream).
    private static let inputStallSeconds = 1.0

    private let runtime: WhisperRuntime
    private let lock = NSLock()
    private var segmenter = WhisperSegmenter()
    private var converter: AVAudioConverter?
    private var lastFeedAt = Date.distantPast
    private var isStopping = false
    private var worker: Task<Void, Never>?

    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?

    init(runtime: WhisperRuntime) {
        self.runtime = runtime
    }

    func start() async throws {
        let worker = Task.detached { [self] in await runWorker() }
        lock.withLock { self.worker = worker }
    }

    /// Thread-safe: convert + buffer from the audio capture queue.
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !isStopping, let samples = convertToTargetFormat(buffer), !samples.isEmpty else { return }
            segmenter.append(samples)
            lastFeedAt = Date()
        }
    }

    func stop() async {
        let worker = lock.withLock {
            isStopping = true
            return self.worker
        }
        await worker?.value
    }

    private func runWorker() async {
        // Last live caption of the current utterance, used if its final decode comes back empty.
        var lastPartial: String?
        var stabilizer = PartialTextStabilizer()

        while true {
            let (work, stopping) = lock.withLock {
                if isStopping {
                    return (segmenter.flush().map(WhisperSegmenter.Work.final), true)
                }
                let stalled = Date().timeIntervalSince(lastFeedAt) > Self.inputStallSeconds
                return (segmenter.nextWork(inputStalled: stalled), false)
            }

            switch work {
            case .partial(let samples):
                if let text = await decode(samples), !text.isEmpty {
                    lastPartial = text
                    if let caption = stabilizer.update(with: text) {
                        await deliver(caption, isFinal: false)
                    }
                }
            case .final(let samples):
                let decoded = await decode(samples)
                let text = decoded.flatMap { $0.isEmpty ? nil : $0 } ?? lastPartial
                lastPartial = nil
                stabilizer.reset()
                if let text {
                    await deliver(text, isFinal: true)
                }
            case nil:
                if stopping { return }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    private func decode(_ samples: [Float]) async -> String? {
        do {
            return try await runtime.transcribe(samples)
        } catch {
            print("Whisper decode failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func deliver(_ text: String, isFinal: Bool) async {
        await MainActor.run {
            if isFinal {
                onFinalResult?(text)
            } else {
                onPartialResult?(text)
            }
        }
    }

    /// Keeps one converter per source format so resampler state carries across buffers,
    /// which avoids clicks at buffer boundaries. Caller holds `lock`.
    private func convertToTargetFormat(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.targetFormat)
            converter?.downmix = true
        }
        guard let converter else { return nil }

        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var error: NSError?
        var consumed = false
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
