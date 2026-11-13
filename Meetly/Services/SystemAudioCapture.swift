import AppKit
import AVFoundation
import Foundation
import ScreenCaptureKit
import VideoToolbox

@MainActor
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, SCContentSharingPickerObserver {
    private var stream: SCStream?
    private var isRunning = false
    private var pickerContinuation: CheckedContinuation<Void, Error>?
    private var isObservingPicker = false
    /// What the running stream captures. Screenshots reuse it, because it's already approved
    /// through the picker and asking for shareable content would re-trigger the permission dialog.
    private var activeFilter: SCContentFilter?
    nonisolated let frameGrabber = ScreenFrameGrabber()
    private static let frameQueue = DispatchQueue(label: "Meetly.ScreenFrames", qos: .userInitiated)

    /// Invoked on the ScreenCaptureKit sample-handler queue — keep handlers off the main actor.
    nonisolated(unsafe) var onBuffer: ((AVAudioPCMBuffer) -> Void)?

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

    var canCaptureScreenshot: Bool {
        activeFilter != nil
    }

    /// The display the running stream (and so screenshots) currently covers.
    var capturedDisplayID: CGDirectDisplayID? {
        activeFilter?.includedDisplays.first?.displayID
    }

    /// Reopens the share picker for the running stream so the user can move it to another
    /// display. Only the stream's content changes; audio keeps flowing.
    func changeDisplayViaPicker() async throws {
        guard let stream else { throw CaptureError.noDisplayAvailable }

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
        picker.setConfiguration(pickerConfiguration, for: stream)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pickerContinuation = continuation
            picker.present(for: stream, using: .display)
        }
    }

    /// Takes one full-size frame from the running stream. `SCScreenshotManager` can't be used:
    /// the picker's approval only covers this stream, so a screenshot call checks Screen Recording
    /// permission and fails whenever the grant doesn't match the build.
    func captureScreenshot() async throws -> CGImage {
        guard let stream, let filter = activeFilter else {
            throw CaptureError.noDisplayAvailable
        }

        let configuration = makeStreamConfiguration()
        let size = filter.contentRect.size
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = size.width > 0 ? Int(size.width * scale) : 1920
        configuration.height = size.height > 0 ? Int(size.height * scale) : 1080
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)

        frameGrabber.arm()
        do {
            try await stream.updateConfiguration(configuration)
        } catch {
            frameGrabber.cancel()
            throw error
        }
        let result = await Result { try await frameGrabber.nextFrame(timeout: .seconds(3)) }
        // Back to tiny frames so the stream stays cheap for audio.
        try? await stream.updateConfiguration(makeStreamConfiguration())
        return try result.get()
    }

    func stop() async {
        activeFilter = nil
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
        // `displays` isn't ordered by main display; prefer the screen the user is on.
        let preferredID = DisplayLocator.displayUnderPointer() ?? CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == preferredID })
            ?? content.displays.first else {
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
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: Self.frameQueue)
        try await stream.startCapture()
        self.stream = stream
        activeFilter = filter
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
                    activeFilter = filter
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
        if type == .screen {
            frameGrabber.handle(sampleBuffer)
            return
        }
        guard type == .audio else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

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

    enum CaptureError: LocalizedError {
        case noDisplayAvailable
        case pickerCancelled
        case screenFrameTimedOut

        var errorDescription: String? {
            switch self {
            case .noDisplayAvailable:
                "No display available for system audio capture."
            case .pickerCancelled:
                ScreenCapturePermission.pickerCancelledMessage
            case .screenFrameTimedOut:
                "The shared display didn't send a frame in time. Try again."
            }
        }
    }
}

enum DisplayLocator {
    /// The display containing the mouse pointer, i.e. the screen the user is looking at.
    @MainActor
    static func displayUnderPointer() -> CGDirectDisplayID? {
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
        return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Hands the next full-size video frame from the stream to a waiting screenshot request.
/// Frames arrive on the ScreenCaptureKit queue, so state is lock-guarded.
final class ScreenFrameGrabber: @unchecked Sendable {
    private let lock = NSLock()
    private var isArmed = false
    private var pendingResult: Result<CGImage, Error>?
    private var continuation: CheckedContinuation<CGImage, Error>?

    /// Call before resizing the stream, so a frame that arrives before `nextFrame` isn't lost.
    func arm() {
        lock.lock()
        isArmed = true
        pendingResult = nil
        lock.unlock()
    }

    func nextFrame(timeout: Duration) async throws -> CGImage {
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.finish(.failure(SystemAudioCapture.CaptureError.screenFrameTimedOut))
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pendingResult {
                self.pendingResult = nil
                isArmed = false
                lock.unlock()
                continuation.resume(with: pendingResult)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
        lock.lock()
        pendingResult = nil
        lock.unlock()
    }

    func handle(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let isArmed = self.isArmed
        lock.unlock()
        guard isArmed,
              Self.isCompleteFrame(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              // Skip the tiny audio-only frames still in flight from before the resize.
              CVPixelBufferGetWidth(pixelBuffer) > 16
        else { return }

        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        guard let image else { return }
        finish(.success(image))
    }

    private func finish(_ result: Result<CGImage, Error>) {
        lock.lock()
        guard isArmed else {
            lock.unlock()
            return
        }
        isArmed = false
        guard let continuation else {
            pendingResult = result
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        return status == .complete
    }
}
