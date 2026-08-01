import AVFoundation
import Foundation

@MainActor
final class LiveTranscriptionService {
    private var micChannel: AppleSpeechChannel?
    private var systemChannel: AppleSpeechChannel?
    private var isStartingSystemChannel = false
    private var transcriptionLocale: Locale?
    private var localeReserved = false

    var onPartialResult: ((String, Speaker) -> Void)?
    var onFinalResult: ((String, Speaker) -> Void)?

    func prepare() async throws {
        guard await AppleSpeechChannel.requestAuthorization() else {
            throw AppleSpeechError.notAuthorized
        }

        let locale = try await AppleSpeechChannel.resolveLocale()
        transcriptionLocale = locale
        try await AppleSpeechChannel.prepareAssets(for: locale)
    }

    func start() async throws {
        let locale = try await resolvedLocale()
        if !localeReserved {
            try await AppleSpeechChannel.reserveLocale(locale)
            localeReserved = true
        }

        let mic = AppleSpeechChannel()
        wireCallbacks(for: mic, speaker: .me)
        try await mic.start(locale: locale)
        micChannel = mic
    }

    func feedMicBuffer(_ buffer: AVAudioPCMBuffer) {
        micChannel?.feed(buffer)
    }

    func feedSystemBuffer(_ buffer: AVAudioPCMBuffer) {
        if let systemChannel {
            systemChannel.feed(buffer)
            return
        }

        guard !isStartingSystemChannel else { return }
        isStartingSystemChannel = true

        Task { @MainActor in
            defer { isStartingSystemChannel = false }
            do {
                let locale = try await resolvedLocale()
                let channel = AppleSpeechChannel()
                wireCallbacks(for: channel, speaker: .other)
                try await channel.start(locale: locale)
                systemChannel = channel
                channel.feed(buffer)
            } catch {
                print("System speech channel failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() async {
        await micChannel?.stop()
        await systemChannel?.stop()
        micChannel = nil
        systemChannel = nil
        isStartingSystemChannel = false

        if localeReserved, let transcriptionLocale {
            await AppleSpeechChannel.releaseLocale(transcriptionLocale)
            localeReserved = false
        }
    }

    private func resolvedLocale() async throws -> Locale {
        if let transcriptionLocale {
            return transcriptionLocale
        }
        let locale = try await AppleSpeechChannel.resolveLocale()
        transcriptionLocale = locale
        return locale
    }

    private func wireCallbacks(for channel: AppleSpeechChannel, speaker: Speaker) {
        channel.onPartialResult = { [weak self] text in
            self?.onPartialResult?(text, speaker)
        }
        channel.onFinalResult = { [weak self] text in
            self?.onFinalResult?(text, speaker)
        }
    }
}
