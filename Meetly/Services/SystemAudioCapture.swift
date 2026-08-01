import AVFoundation
import Foundation
import ScreenCaptureKit

@MainActor
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, SCContentSharingPickerObserver {
    private var stream: SCStream?
    private var isRunning = false
    private var pickerContinuation: CheckedContinuation<Void, Error>?
    private var isObservingPicker = false

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start() async throws {
        guard !isRunning else { return }
        try await startProgrammatic()
    }

    /// Presents the system content picker so the user can grant capture without Screen Recording TCC.
    func startViaContentPicker() async throws {
        guard !isRunning else { return }

        let picker = SCContentSharingPicker.shared
        if !isObservingPicker {
            picker.add(self)
            isObservingPicker = true
        }
        picker.isActive = true

        var pickerConfiguration = SCContentSharingPickerConfiguration()
        pickerConfiguration.allowedPickerModes = [.singleDisplay]
        if let bundleID = Bundle.main.bundleIdentifier {
            pickerConfiguration.excludedBundleIDs = [bundleID]
        }
        picker.defaultConfiguration = pickerConfiguration

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pickerContinuation = continuation
            picker.present(using: .display)
        }
    }

    func stop() async {
        if isObservingPicker {
            SCContentSharingPicker.shared.remove(self)
            isObservingPicker = false
        }
        SCContentSharingPicker.shared.isActive = false

        guard isRunning, let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            // Best-effort stop.
        }
        self.stream = nil
        isRunning = false
    }

    // MARK: - Programmatic capture

    private func startProgrammatic() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplayAvailable
        }

        let excludingApps = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display, excludingApplications: excludingApps, exceptingWindows: [])
        try await startStream(with: filter)
    }

    private func startStream(with filter: SCContentFilter) async throws {
        let configuration = makeStreamConfiguration()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()
        self.stream = stream
        isRunning = true
    }

    private func makeStreamConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        return configuration
    }

    // MARK: - SCContentSharingPickerObserver

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            do {
                if let stream {
                    try await stream.updateContentFilter(filter)
                    self.stream = stream
                    if !isRunning {
                        try await stream.startCapture()
                    }
                } else {
                    try await startStream(with: filter)
                }
                isRunning = true
                resumePickerContinuation()
            } catch {
                failPickerContinuation(error)
            }
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            failPickerContinuation(CaptureError.pickerCancelled)
        }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            failPickerContinuation(error)
        }
    }

    private func resumePickerContinuation() {
        pickerContinuation?.resume()
        pickerContinuation = nil
    }

    private func failPickerContinuation(_ error: Error) {
        pickerContinuation?.resume(throwing: error)
        pickerContinuation = nil
    }

    // MARK: - SCStreamOutput

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        Task { @MainActor in
            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
                  let sourceFormat = AVAudioFormat(streamDescription: streamDescription) else {
                return
            }

            let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frameCount > 0,
                  let sourceBuffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat,
                    frameCapacity: AVAudioFrameCount(frameCount)
                  ) else {
                return
            }

            sourceBuffer.frameLength = AVAudioFrameCount(frameCount)
            let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer,
                at: 0,
                frameCount: Int32(frameCount),
                into: sourceBuffer.mutableAudioBufferList
            )
            guard copyStatus == noErr else { return }
            onBuffer?(sourceBuffer)
        }
    }

    enum CaptureError: LocalizedError {
        case noDisplayAvailable
        case pickerCancelled

        var errorDescription: String? {
            switch self {
            case .noDisplayAvailable:
                "No display available for system audio capture."
            case .pickerCancelled:
                ScreenCapturePermission.pickerCancelledMessage
            }
        }
    }
}
