import AppKit
import Foundation
import os

/// A browser whose tabs can be checked for a meeting. Add a case to support another browser
/// that answers `URL of tabs of windows` over AppleScript (Chromium browsers and Safari do).
nonisolated enum MeetingBrowser: CaseIterable, Sendable {
    case chrome
    case safari
    case edge
    case brave
    case arc
    case vivaldi
    case chromium

    var name: String {
        switch self {
        case .chrome: "Chrome"
        case .safari: "Safari"
        case .edge: "Microsoft Edge"
        case .brave: "Brave"
        case .arc: "Arc"
        case .vivaldi: "Vivaldi"
        case .chromium: "Chromium"
        }
    }

    var applicationBundleID: String {
        switch self {
        case .chrome: "com.google.Chrome"
        case .safari: "com.apple.Safari"
        case .edge: "com.microsoft.edgemac"
        case .brave: "com.brave.Browser"
        case .arc: "company.thebrowser.Browser"
        case .vivaldi: "com.vivaldi.Vivaldi"
        case .chromium: "org.chromium.Chromium"
        }
    }

    /// Safari's audio runs in a shared WebKit process, so other apps' web views also report this ID.
    func ownsAudioProcess(bundleID: String) -> Bool {
        switch self {
        case .safari: bundleID == "com.apple.WebKit.GPU"
        default: bundleID.matchesBundleID(applicationBundleID)
        }
    }
}

/// Looks for a meeting in a running browser's open tabs.
///
/// URLs stay in this file: they are matched here and never logged or stored.
nonisolated enum BrowserMeetingProbe {
    enum Result: Sendable, Equatable {
        case meeting(name: String)
        case notMeeting
        /// The browser isn't running, so something else is using its audio process.
        case notRunning
        /// The user declined the macOS Automation prompt for this browser.
        case notAuthorized
        /// The browser didn't answer this time, for example because a prompt is still open.
        case unavailable
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Meetly",
        category: "MeetingDetection"
    )

    private static let automationDeniedError = "-1743"
    /// Long enough for the user to answer the Automation prompt on first use.
    private static let timeout: TimeInterval = 60

    private static let meetingPatterns: [(name: String, pattern: String)] = [
        // Meet can put extra path segments before the room code.
        ("Google Meet", #"meet\.google\.com/(?:[^/,\s?#]+/)*[a-z]{3}-[a-z]{4}-[a-z]{3}(?![a-z0-9-])"#),
        ("Microsoft Teams", #"teams\.(microsoft\.com|live\.com|cloud\.microsoft)"#),
        ("Zoom", #"(^|[/.])zoom\.(us|com)/(wc|j|my|s)/"#),
        ("Webex", #"\.webex\.com/(meet|join|wbxmjs|webappng|[^/,\s]+/j\.php)"#),
        ("Slack huddle", #"app\.slack\.com/huddle/"#),
        ("Discord", #"discord\.com/channels/"#),
        ("Whereby", #"whereby\.com/[^/,\s?#]+"#),
        ("Jitsi Meet", #"(meet\.jit\.si|8x8\.vc)/[^/,\s?#]+"#),
        ("GoTo Meeting", #"(meet\.goto\.com|app\.goto\.com/meeting|global\.gotomeeting\.com/join)/"#),
        ("Amazon Chime", #"app\.chime\.aws/meetings/"#),
        ("RingCentral", #"v\.ringcentral\.com/(join|conf)/"#),
        ("Zoho Meeting", #"meeting\.zoho\.[a-z.]+/"#),
        ("Skype", #"(web|join)\.skype\.com/"#),
        ("WhatsApp", #"web\.whatsapp\.com"#),
        ("Messenger", #"(messenger|facebook)\.com/groupcall/"#),
        ("Gather", #"app\.gather\.town/"#),
        ("Around", #"around\.co/[^/,\s?#]+"#),
        ("Riverside", #"riverside\.(fm|com)/studio/"#),
        ("StreamYard", #"streamyard\.com/[a-z0-9]+"#),
        ("Lark", #"(larksuite|feishu)\.(com|cn)/(meeting|vc)/"#),
    ]

    static func check(_ browser: MeetingBrowser) async -> Result {
        // `tell application` would launch a browser that isn't running.
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: browser.applicationBundleID
        ).isEmpty else {
            return .notRunning
        }

        let script = "tell application id \"\(browser.applicationBundleID)\" to get URL of tabs of windows"
        let output = await runAppleScript(script)

        guard output.succeeded else {
            // Only the error number: the rest of the output could include tab addresses.
            let errorCode = output.errorText.range(of: #"\(-?\d+\)"#, options: .regularExpression)
                .map { String(output.errorText[$0]) } ?? "unknown"
            logger.notice("\(browser.name, privacy: .public) tab check failed: \(errorCode, privacy: .public)")
            return output.errorText.contains(automationDeniedError) ? .notAuthorized : .unavailable
        }

        let match = meetingPatterns.first {
            output.text.range(of: $0.pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return match.map { .meeting(name: $0.name) } ?? .notMeeting
    }

    private struct ScriptOutput: Sendable {
        let succeeded: Bool
        let text: String
        let errorText: String
    }

    /// Runs in `osascript` because `NSAppleScript` would block its thread while the consent prompt is open.
    private static func runAppleScript(_ script: String) async -> ScriptOutput {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let standardOutput = Pipe()
                let standardError = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                process.standardOutput = standardOutput
                process.standardError = standardError

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ScriptOutput(succeeded: false, text: "", errorText: ""))
                    return
                }

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }

                // Read before waiting: a long tab list would otherwise fill the pipe and stall the script.
                let textData = standardOutput.fileHandleForReading.readDataToEndOfFile()
                let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                continuation.resume(returning: ScriptOutput(
                    succeeded: process.terminationStatus == 0,
                    text: String(decoding: textData, as: UTF8.self),
                    errorText: String(decoding: errorData, as: UTF8.self)
                ))
            }
        }
    }
}
