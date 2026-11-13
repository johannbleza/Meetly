import Foundation
import WhisperKit

/// A loaded Whisper model shared by the mic and system channels.
/// Decodes run one at a time, so two channels never contend for the model.
actor WhisperRuntime {
    private let pipe: WhisperKit
    private let options: DecodingOptions
    private var lastDecode: Task<Void, Never>?

    init(modelFolder: URL, tokenizerFolder: URL, locale: Locale = .current) async throws {
        pipe = try await WhisperKit(WhisperKitConfig(
            modelFolder: modelFolder.path,
            tokenizerFolder: tokenizerFolder,
            verbose: false,
            load: true,
            download: false
        ))
        options = Self.decodingOptions(for: locale)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let previous = lastDecode
        let pipe = pipe
        let options = options
        let decode = Task {
            await previous?.value
            return try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        }
        lastDecode = Task { _ = await decode.result }

        let results = try await decode.value
        return Self.cleanedText(results.map(\.text).joined(separator: " "))
    }

    func unload() async {
        await lastDecode?.value
        await pipe.unloadModels()
    }

    private static func decodingOptions(for locale: Locale) -> DecodingOptions {
        // Pin the language when Whisper knows it: detecting per utterance flips languages on short clips.
        let code = locale.language.languageCode?.identifier
        let language = code.flatMap { Constants.languageCodes.contains($0) ? $0 : nil }
        return DecodingOptions(
            language: language,
            // Fewer retries than the default of 5, to keep up with live audio.
            temperatureFallbackCount: 1,
            usePrefillPrompt: language != nil,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
    }

    /// Whisper labels non-speech like "[BLANK_AUDIO]" or "(music)"; those aren't transcript.
    private static func cleanedText(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
