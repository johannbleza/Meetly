import AVFoundation
import Foundation

@MainActor
final class LiveTranscriptionService {
    private final class ChannelStorage: @unchecked Sendable {
        private let lock = NSLock()
        private var mic: AppleSpeechChannel?
        private var system: AppleSpeechChannel?

        func set(mic: AppleSpeechChannel?, system: AppleSpeechChannel?) {
            lock.lock()
            self.mic = mic
            self.system = system
            lock.unlock()
        }

        func setSystem(_ system: AppleSpeechChannel?) {
            lock.lock()
            self.system = system
            lock.unlock()
        }

        func take() -> (AppleSpeechChannel?, AppleSpeechChannel?) {
            lock.lock()
            let pair = (mic, system)
            mic = nil
            system = nil
            lock.unlock()
            return pair
        }

        func micChannel() -> AppleSpeechChannel? {
            lock.lock()
            defer { lock.unlock() }
            return mic
        }

        func systemChannel() -> AppleSpeechChannel? {
            lock.lock()
            defer { lock.unlock() }
            return system
        }
    }

    private let channels = ChannelStorage()
    private var transcriptionLocale: Locale?
    private var localeReserved = false
    private var isStartingSystemChannel = false

    var onPartialResult: ((String, Speaker) -> Void)?
    var onFinalResult: ((String, Speaker) -> Void)?
    var onSystemChannelError: ((Error) -> Void)?

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
        channels.set(mic: mic, system: nil)

        // Eager-start the system channel so meeting audio has no cold-start gap.
        await startSystemChannelIfNeeded(reportErrors: false)
    }

    nonisolated func feedMicBuffer(_ buffer: AVAudioPCMBuffer) {
        channels.micChannel()?.feed(buffer)
    }

    nonisolated func feedSystemBuffer(_ buffer: AVAudioPCMBuffer) {
        if let system = channels.systemChannel() {
            system.feed(buffer)
            return
        }

        Task { @MainActor in
            await startSystemChannelIfNeeded(reportErrors: true)
        }
    }

    func pause() async {
        isStartingSystemChannel = false
        let (mic, system) = channels.take()
        await mic?.stop()
        await system?.stop()
    }

    func resume() async throws {
        try await start()
    }

    func stop() async {
        await pause()

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

    private func startSystemChannelIfNeeded(reportErrors: Bool) async {
        guard channels.systemChannel() == nil, !isStartingSystemChannel else { return }
        isStartingSystemChannel = true
        defer { isStartingSystemChannel = false }

        do {
            let locale = try await resolvedLocale()
            let system = AppleSpeechChannel()
            wireCallbacks(for: system, speaker: .other)
            try await system.start(locale: locale)
            channels.setSystem(system)
        } catch {
            if reportErrors {
                onSystemChannelError?(error)
            }
        }
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
