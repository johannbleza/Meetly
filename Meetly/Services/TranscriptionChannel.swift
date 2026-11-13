import AVFoundation
import Foundation

/// The speech-to-text backend used for live transcription.
enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case appleSpeech
    case whisper

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleSpeech: "Apple Speech"
        case .whisper: "Whisper"
        }
    }

    var settingsDescription: String {
        switch self {
        case .appleSpeech:
            "Built into macOS, with the lowest latency and power use. Live captions update word by word."
        case .whisper:
            "Runs OpenAI's Whisper models on this Mac; audio is never uploaded. Often more accurate, but uses more power, and live captions trail speech by a second or two."
        }
    }
}

/// One source's speech-to-text stream. Mic and system audio each get their own channel.
///
/// `feed` is called on capture threads and must never hop to the MainActor.
/// Result callbacks are delivered on the MainActor.
nonisolated protocol TranscriptionChannel: AnyObject, Sendable {
    var onPartialResult: ((String) -> Void)? { get set }
    var onFinalResult: ((String) -> Void)? { get set }

    func start() async throws
    func feed(_ buffer: AVAudioPCMBuffer)
    /// Finishes any buffered audio; final results are delivered before this returns.
    func stop() async
}
