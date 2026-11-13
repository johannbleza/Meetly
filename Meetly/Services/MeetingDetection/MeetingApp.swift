import AppKit
import Foundation

/// A native app whose mic use always means a call. Add an entry to support another app.
nonisolated struct MeetingApp: Hashable, Sendable {
    let name: String
    /// Matched exactly or as a prefix followed by ".", so helper processes count too.
    let bundleIDs: [String]

    static let all: [MeetingApp] = [
        MeetingApp(name: "Microsoft Teams", bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"]),
        MeetingApp(name: "Zoom", bundleIDs: ["us.zoom.xos"]),
        MeetingApp(name: "Webex", bundleIDs: ["Cisco-Systems.Spark", "com.cisco.webexmeetingsapp", "com.webex.meetingmanager"]),
        MeetingApp(name: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"]),
        // FaceTime and iPhone calls on the Mac run their audio in avconferenced.
        MeetingApp(name: "FaceTime", bundleIDs: ["com.apple.FaceTime", "com.apple.avconferenced"]),
        MeetingApp(name: "Discord", bundleIDs: ["com.hnc.Discord"]),
        MeetingApp(name: "Skype", bundleIDs: ["com.skype.skype"]),
        MeetingApp(name: "GoTo Meeting", bundleIDs: ["com.logmein.GoToMeeting", "com.logmein.goto"]),
        MeetingApp(name: "RingCentral", bundleIDs: ["com.ringcentral.glip", "com.ringcentral.RingCentralMeetings"]),
        MeetingApp(name: "Amazon Chime", bundleIDs: ["com.amazon.Amazon-Chime"]),
        MeetingApp(name: "BlueJeans", bundleIDs: ["com.bluejeansnet.Blue"]),
        MeetingApp(name: "Whereby", bundleIDs: ["com.whereby.app"]),
        MeetingApp(name: "Tuple", bundleIDs: ["app.tuple.app"]),
        MeetingApp(name: "Around", bundleIDs: ["co.teamport.around"]),
        MeetingApp(name: "Lark", bundleIDs: ["com.bytedance.lark", "com.electron.lark"]),
        MeetingApp(name: "Signal", bundleIDs: ["org.whispersystems.signal-desktop"]),
        MeetingApp(name: "WhatsApp", bundleIDs: ["net.whatsapp.WhatsApp", "desktop.WhatsApp"]),
        MeetingApp(name: "Telegram", bundleIDs: ["ru.keepcoder.Telegram", "org.telegram.desktop"]),
        MeetingApp(name: "Messenger", bundleIDs: ["com.facebook.archon"]),
        MeetingApp(name: "Zoho Meeting", bundleIDs: ["com.zoho.meeting"]),
    ]

    func ownsAudioProcess(bundleID: String) -> Bool {
        bundleIDs.contains { bundleID.matchesBundleID($0) }
    }
}

/// Names apps that hold the mic but aren't in the known lists, so any call app still gets a prompt.
nonisolated enum OtherMicApp {
    /// Apps that hold the mic for something other than a call.
    private static let ignoredBundleIDs: [String] = [
        "com.apple.VoiceMemos",
        "com.apple.PhotoBooth",
        "com.apple.QuickTimePlayerX",
        "com.apple.garageband10",
        "com.apple.logic10",
        "com.apple.FinalCut",
        "com.electron.wispr-flow",
        "com.superduper.superwhisper",
        "com.goodsnooze.MacWhisper",
        "com.goodsnooze.macwhisper",
        "so.granola.app",
        "com.granola.app",
        "com.obsproject.obs-studio",
        "com.loom.desktop",
        "com.techsmith.camtasia",
        "com.cleanshot.CleanShot",
        "pl.maketheweb.cleanshotx",
    ]

    struct Identity: Sendable {
        let bundleID: String
        let name: String
    }

    /// Resolves an audio process to its app, or nil for daemons, system services, and ignored apps.
    static func identify(bundleID: String) -> Identity? {
        // Siri, dictation, Sound Recognition and other system services aren't calls.
        // FaceTime and Safari are handled by the known lists before this runs.
        if bundleID.hasPrefix("com.apple.") && !isAppleApp(bundleID) { return nil }
        guard !ignoredBundleIDs.contains(where: { bundleID.matchesBundleID($0) }) else { return nil }

        // Helper processes ("com.example.app.helper") report their own ID, so walk up to the app.
        var components = bundleID.split(separator: ".").map(String.init)
        while components.count >= 2 {
            let candidate = components.joined(separator: ".")
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate),
               url.pathExtension == "app",
               !isNestedHelper(url) {
                return Identity(bundleID: candidate, name: displayName(of: url))
            }
            components.removeLast()
        }
        return nil
    }

    private static func isAppleApp(_ bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        return url.path.hasPrefix("/Applications/") || url.path.hasPrefix("/System/Applications/")
    }

    /// Helper apps live inside another app's bundle; the outer app is the one to name.
    private static func isNestedHelper(_ url: URL) -> Bool {
        url.deletingLastPathComponent().path.contains(".app/")
    }

    private static func displayName(of url: URL) -> String {
        let info = Bundle(url: url)?.infoDictionary
        return (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

nonisolated extension String {
    func matchesBundleID(_ bundleID: String) -> Bool {
        self == bundleID || hasPrefix(bundleID + ".")
    }
}
