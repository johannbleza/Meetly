import AVFoundation
import Foundation

@MainActor
final class LiveTranscriptionService {
    private final class ChannelStorage: @unchecked Sendable {
        private let lock = NSLock()
        private var mic: (any TranscriptionChannel)?
        private var system: (any TranscriptionChannel)?

        func set(mic: (any TranscriptionChannel)?, system: (any TranscriptionChannel)?) {
            lock.lock()
            self.mic = mic
            self.system = system
            lock.unlock()
        }

        func setSystem(_ system: (any TranscriptionChannel)?) {
            lock.lock()
            self.system = system
            lock.unlock()
        }

        func take() -> ((any TranscriptionChannel)?, (any TranscriptionChannel)?) {
            lock.lock()
            let pair = (mic, system)
            mic = nil
            system = nil
            lock.unlock()
            return pair
        }

        func micChannel() -> (any TranscriptionChannel)? {
            lock.lock()
            defer { lock.unlock() }
            return mic
        }

        func systemChannel() -> (any TranscriptionChannel)? {
            lock.lock()
            defer { lock.unlock() }
            return system
        }
    }

    private let channels = ChannelStorage()
    private var transcriptionLocale: Locale?
    private var localeReserved = false
    private var isStartingSystemChannel = false
    private var whisperRuntime: WhisperRuntime?

    /// Set when the selected engine couldn't be used and this meeting fell back to Apple Speech.
    private(set) var fallbackNotice: String?

    var onPartialResult: ((String, Speaker) -> Void)?
    var onFinalResult: ((String, Speaker) -> Void)?
    var onSystemChannelError: ((Error) -> Void)?

    func prepare() async throws {
        fallbackNotice = nil

        if AppSettings.transcriptionEngine == .whisper {
            do {
                whisperRuntime = try await WhisperModelStore.shared.loadRuntime(for: AppSettings.whisperModel)
                return
            } catch {
                // A meeting is time-critical: keep transcribing rather than failing to start.
                fallbackNotice = "\(error.localizedDescription) Using Apple Speech for this meeting."
            }
        }

        guard await AppleSpeechChannel.requestAuthorization() else {
            throw AppleSpeechError.notAuthorized
        }

        let locale = try await AppleSpeechChannel.resolveLocale()
        transcriptionLocale = locale
        try await AppleSpeechChannel.prepareAssets(for: locale)
    }

    func start() async throws {
        if whisperRuntime == nil {
            let locale = try await resolvedLocale()
            if !localeReserved {
                try await AppleSpeechChannel.reserveLocale(locale)
                localeReserved = true
            }
        }

        let mic = try await makeChannel()
        wireCallbacks(for: mic, speaker: .me)
        try await mic.start()
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

        await whisperRuntime?.unload()
        whisperRuntime = nil
    }

    private func makeChannel() async throws -> any TranscriptionChannel {
        if let whisperRuntime {
            return WhisperChannel(runtime: whisperRuntime)
        }
        return AppleSpeechChannel(locale: try await resolvedLocale())
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
            let system = try await makeChannel()
            wireCallbacks(for: system, speaker: .other)
            try await system.start()
            channels.setSystem(system)
        } catch {
            if reportErrors {
                onSystemChannelError?(error)
            }
        }
    }

    private func wireCallbacks(for channel: any TranscriptionChannel, speaker: Speaker) {
        channel.onPartialResult = { [weak self] text in
            self?.onPartialResult?(text, speaker)
        }
        channel.onFinalResult = { [weak self] text in
            self?.onFinalResult?(text, speaker)
        }
    }
}
