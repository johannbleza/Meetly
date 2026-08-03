import AVFoundation
import Foundation
import Speech

enum AppleSpeechError: LocalizedError {
    case assetsUnavailable
    case noSupportedAudioFormat
    case notAuthorized
    case unsupportedLocale

    var errorDescription: String? {
        switch self {
        case .assetsUnavailable:
            "On-device speech models are not available."
        case .noSupportedAudioFormat:
            "Could not configure speech audio format."
        case .notAuthorized:
            "Speech recognition permission is required."
        case .unsupportedLocale:
            "No supported speech recognition language is installed on this Mac."
        }
    }
}

/// Feeds PCM off the main actor; result callbacks are delivered on the MainActor.
final class AppleSpeechChannel: @unchecked Sendable {
    private static let liveReportingOptions: Set<SpeechTranscriber.ReportingOption> = [
        .volatileResults,
        .fastResults,
    ]

    private let stateLock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var resultTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?

    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    static func resolveLocale(preferred: Locale = .current) async throws -> Locale {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) {
            return match
        }

        let installed = await SpeechTranscriber.installedLocales
        if let installedMatch = installed.first(where: { $0.language.languageCode == preferred.language.languageCode }) {
            return installedMatch
        }
        if let firstInstalled = installed.first {
            return firstInstalled
        }

        let fallbacks = ["en-US", "en-GB", "en"]
        for identifier in fallbacks {
            let candidate = Locale(identifier: identifier)
            if let match = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) {
                return match
            }
        }

        let supported = await SpeechTranscriber.supportedLocales
        if let firstSupported = supported.first {
            return firstSupported
        }

        throw AppleSpeechError.unsupportedLocale
    }

    static func makeLiveTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: liveReportingOptions,
            attributeOptions: []
        )
    }

    static func prepareAssets(for locale: Locale) async throws {
        let transcriber = makeLiveTranscriber(locale: locale)
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status != .installed else { return }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            throw AppleSpeechError.assetsUnavailable
        }
        try await request.downloadAndInstall()
    }

    static func reserveLocale(_ locale: Locale) async throws {
        _ = try await AssetInventory.reserve(locale: locale)
    }

    static func releaseLocale(_ locale: Locale) async {
        _ = await AssetInventory.release(reservedLocale: locale)
    }

    func start(locale: Locale) async throws {
        let transcriber = Self.makeLiveTranscriber(locale: locale)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppleSpeechError.noSupportedAudioFormat
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)

        stateLock.lock()
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.analyzerFormat = format
        self.inputContinuation = continuation
        stateLock.unlock()

        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    let isFinal = result.isFinal
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if isFinal {
                            self.onFinalResult?(text)
                        } else {
                            self.onPartialResult?(text)
                        }
                    }
                }
            } catch {
                print("Apple Speech result stream ended: \(error.localizedDescription)")
            }
        }
    }

    /// Thread-safe: convert + yield from the audio capture queue.
    func feed(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let format = analyzerFormat
        let continuation = inputContinuation
        stateLock.unlock()

        guard let format, let continuation else { return }
        let prepared = AudioFormatConverter.convert(buffer, to: format) ?? buffer
        continuation.yield(AnalyzerInput(buffer: prepared))
    }

    func stop() async {
        stateLock.lock()
        inputContinuation?.finish()
        inputContinuation = nil
        let analyzer = self.analyzer
        self.analyzer = nil
        self.transcriber = nil
        self.analyzerFormat = nil
        let task = resultTask
        resultTask = nil
        stateLock.unlock()

        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        task?.cancel()
    }
}
