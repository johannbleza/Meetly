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

@MainActor
final class AppleSpeechChannel {
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

    static func prepareAssets(for locale: Locale) async throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
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
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppleSpeechError.noSupportedAudioFormat
        }
        analyzerFormat = format

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation
        try await analyzer.start(inputSequence: stream)

        resultTask = Task { [weak self] in
            guard let transcriber = self?.transcriber else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    if result.isFinal {
                        self?.onFinalResult?(text)
                    } else {
                        self?.onPartialResult?(text)
                    }
                }
            } catch {
                print("Apple Speech result stream ended: \(error.localizedDescription)")
            }
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let analyzerFormat else { return }
        let prepared = AudioFormatConverter.convert(buffer, to: analyzerFormat) ?? buffer
        inputContinuation?.yield(AnalyzerInput(buffer: prepared))
    }

    func stop() async {
        inputContinuation?.finish()
        inputContinuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultTask?.cancel()
        resultTask = nil
        analyzer = nil
        transcriber = nil
        analyzerFormat = nil
    }
}
