import Foundation
import Observation
import os

/// An app that can host a call.
nonisolated enum MeetingSource: Hashable, Sendable {
    /// A known call app: holding the mic means a call.
    case app(MeetingApp)
    /// A browser: its tabs are checked for a meeting link.
    case browser(MeetingBrowser)
    /// Any other app holding the mic. Meetly can't tell if it's a call, so it asks.
    case otherApp(bundleID: String)

    /// Sources checked on every poll, in priority order. Other apps are added as they use the mic.
    static let known: [MeetingSource] = MeetingApp.all.map { .app($0) } + MeetingBrowser.allCases.map { .browser($0) }

    func ownsAudioProcess(bundleID: String) -> Bool {
        switch self {
        case .app(let app): app.ownsAudioProcess(bundleID: bundleID)
        case .browser(let browser): browser.ownsAudioProcess(bundleID: bundleID)
        case .otherApp(let appBundleID): bundleID.matchesBundleID(appBundleID)
        }
    }

    var logName: String {
        switch self {
        case .app(let app): app.name
        case .browser(let browser): browser.name
        case .otherApp(let bundleID): bundleID
        }
    }
}

struct DetectedMeeting: Equatable {
    let source: MeetingSource
    let name: String
    /// False when Meetly only knows the app is using the mic: an unknown app, a browser with
    /// no meeting tab, or a browser whose tabs Meetly isn't allowed to read.
    let isConfirmedMeeting: Bool

    var promptTitle: String {
        isConfirmedMeeting ? "\(name) detected" : "\(name) is using your microphone"
    }
}

/// Publishes the call currently holding the microphone, smoothing over brief changes in mic use.
@MainActor
@Observable
final class MeetingDetector {
    private(set) var activeMeeting: DetectedMeeting?
    /// Called after every poll. Handlers must be safe to run repeatedly.
    @ObservationIgnored var onUpdate: (() -> Void)?

    private struct SourceState {
        var micOnSince: Date?
        var lastMicOnAt: Date?
        var meeting: DetectedMeeting?
        var lastProbeAt: Date?
        var isProbing = false
        var lastProbeResult: BrowserMeetingProbe.Result?
    }

    private static let pollInterval: Duration = .seconds(2)
    /// Mic use must last this long, so a brief test or permission check doesn't prompt.
    private static let confirmationDelay: TimeInterval = 4
    /// The mic must stay released this long before the call counts as over.
    private static let releaseDelay: TimeInterval = 10
    private static let probeInterval: TimeInterval = 5

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Meetly",
        category: "MeetingDetection"
    )

    @ObservationIgnored private var states: [MeetingSource: SourceState] = [:]
    /// Names of unknown apps seen using the mic, keyed by app bundle ID.
    @ObservationIgnored private var otherAppNames: [String: String] = [:]
    /// Audio-process bundle IDs already resolved to an app, or to nil when they aren't one to ask about.
    @ObservationIgnored private var identityCache: [String: OtherMicApp.Identity?] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    private func poll() async {
        guard AppSettings.detectMeetings || AppSettings.autoStopWhenCallEnds else {
            states = [:]
            publish(nil)
            onUpdate?()
            return
        }

        let bundleIDs = await Task.detached(priority: .utility) {
            AudioProcessMonitor.bundleIDsUsingMicrophone()
        }.value

        let now = Date()
        var sources = MeetingSource.known
        for source in sources {
            let isUsingMic = bundleIDs.contains { source.ownsAudioProcess(bundleID: $0) }
            update(source, isUsingMic: isUsingMic, now: now)
        }

        // Anything else holding the mic, such as a call app Meetly doesn't know about.
        let unclaimed = bundleIDs.filter { id in !sources.contains { $0.ownsAudioProcess(bundleID: id) } }
        var otherAppsUsingMic = Set<String>()
        for bundleID in unclaimed {
            let identity: OtherMicApp.Identity?
            if let cached = identityCache[bundleID] {
                identity = cached
            } else {
                identity = OtherMicApp.identify(bundleID: bundleID)
                identityCache[bundleID] = identity
            }
            guard let identity else { continue }
            otherAppNames[identity.bundleID] = identity.name
            otherAppsUsingMic.insert(identity.bundleID)
        }
        // Keep apps that recently released the mic until their release delay passes.
        let trackedOtherApps = states.keys.compactMap { source -> String? in
            if case .otherApp(let bundleID) = source { return bundleID }
            return nil
        }
        for bundleID in otherAppsUsingMic.union(trackedOtherApps).sorted() {
            let source = MeetingSource.otherApp(bundleID: bundleID)
            sources.append(source)
            update(source, isUsingMic: otherAppsUsingMic.contains(bundleID), now: now)
            if states[source]?.micOnSince == nil {
                states[source] = nil
                otherAppNames[bundleID] = nil
            }
        }

        publish(currentMeeting(sources: sources, now: now))
        onUpdate?()
    }

    private func update(_ source: MeetingSource, isUsingMic: Bool, now: Date) {
        var state = states[source] ?? SourceState()

        if isUsingMic {
            if state.micOnSince == nil {
                state.micOnSince = now
                Self.logger.notice("\(source.logName, privacy: .public) started using the mic")
            } else if let lastMicOnAt = state.lastMicOnAt, now.timeIntervalSince(lastMicOnAt) > Self.pollInterval.seconds * 2 {
                Self.logger.notice("\(source.logName, privacy: .public) is using the mic again")
            }
            state.lastMicOnAt = now

            switch source {
            case .app(let app):
                state.meeting = DetectedMeeting(source: source, name: app.name, isConfirmedMeeting: true)
            case .otherApp(let bundleID):
                let name = otherAppNames[bundleID] ?? bundleID
                state.meeting = DetectedMeeting(source: source, name: name, isConfirmedMeeting: false)
            case .browser(let browser):
                if shouldProbe(state, now: now) {
                    state.isProbing = true
                    state.lastProbeAt = now
                    probe(browser, source: source)
                }
            }
        } else if state.micOnSince != nil, let lastMicOnAt = state.lastMicOnAt {
            if now.timeIntervalSince(lastMicOnAt) >= Self.releaseDelay {
                Self.logger.notice("\(source.logName, privacy: .public) released the mic")
                state = SourceState(isProbing: state.isProbing)
            }
        }

        states[source] = state
    }

    private func shouldProbe(_ state: SourceState, now: Date) -> Bool {
        guard !state.isProbing else { return false }
        guard let lastProbeAt = state.lastProbeAt else { return true }
        return now.timeIntervalSince(lastProbeAt) >= Self.probeInterval
    }

    private func probe(_ browser: MeetingBrowser, source: MeetingSource) {
        Task { [weak self] in
            let result = await BrowserMeetingProbe.check(browser)
            self?.applyProbeResult(result, browser: browser, source: source)
        }
    }

    private func applyProbeResult(
        _ result: BrowserMeetingProbe.Result,
        browser: MeetingBrowser,
        source: MeetingSource
    ) {
        guard var state = states[source] else { return }
        state.isProbing = false

        if result != state.lastProbeResult {
            state.lastProbeResult = result
            Self.logger.notice("\(browser.name, privacy: .public) tab check: \(String(describing: result), privacy: .public)")
        }

        // The mic may have been released while the browser was answering.
        if state.micOnSince != nil {
            switch result {
            case .meeting(let name):
                state.meeting = DetectedMeeting(source: source, name: name, isConfirmedMeeting: true)
            case .notAuthorized, .notMeeting:
                // A web call app without a known link still gets a prompt.
                state.meeting = DetectedMeeting(source: source, name: browser.name, isConfirmedMeeting: false)
            case .notRunning:
                state.meeting = nil
            case .unavailable:
                break
            }
        }
        states[source] = state
    }

    private func currentMeeting(sources: [MeetingSource], now: Date) -> DetectedMeeting? {
        func qualifying(_ source: MeetingSource) -> DetectedMeeting? {
            guard let state = states[source], let meeting = state.meeting,
                  let micOnSince = state.micOnSince,
                  now.timeIntervalSince(micOnSince) >= Self.confirmationDelay else {
                return nil
            }
            return meeting
        }

        // Stay on the current call while it qualifies, even if another source also starts using the mic.
        if let source = activeMeeting?.source, let meeting = qualifying(source) {
            return meeting
        }
        let candidates = sources.compactMap(qualifying)
        return candidates.first(where: \.isConfirmedMeeting) ?? candidates.first
    }

    private func publish(_ meeting: DetectedMeeting?) {
        guard meeting != activeMeeting else { return }
        activeMeeting = meeting
        Self.logger.notice("Active meeting: \(meeting?.name ?? "none", privacy: .public)")
    }
}

private extension Duration {
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
