import Foundation

enum AppSettings {
    private static let defaults = UserDefaults.standard

    /// Read when a meeting starts; changes apply to the next meeting.
    static var transcriptionEngine: TranscriptionEngine {
        get {
            guard let rawValue = defaults.string(forKey: "transcriptionEngine"),
                  let engine = TranscriptionEngine(rawValue: rawValue) else {
                return .whisper
            }
            return engine
        }
        set { defaults.set(newValue.rawValue, forKey: "transcriptionEngine") }
    }

    static var whisperModel: WhisperModel {
        get {
            guard let rawValue = defaults.string(forKey: "whisperModel"),
                  let model = WhisperModel(rawValue: rawValue) else {
                return .small
            }
            return model
        }
        set { defaults.set(newValue.rawValue, forKey: "whisperModel") }
    }

    static var aiProvider: AIProvider {
        get {
            guard let rawValue = defaults.string(forKey: "aiProvider"),
                  let provider = AIProvider(rawValue: rawValue) else {
                return .claude
            }
            return provider
        }
        set { defaults.set(newValue.rawValue, forKey: "aiProvider") }
    }

    /// A model name or alias passed to Claude Code. Sonnet keeps live answers quick.
    static var claudeModel: String {
        get { defaults.string(forKey: "claudeModel") ?? "sonnet" }
        set { defaults.set(newValue, forKey: "claudeModel") }
    }

    /// A model name passed to Codex. Empty uses the tool's default.
    static var codexModel: String {
        get { defaults.string(forKey: "codexModel") ?? "" }
        set { defaults.set(newValue, forKey: "codexModel") }
    }

    /// When enabled, Claude and Codex Q&A may search the web for questions that need current or external knowledge.
    static var aiWebSearchEnabled: Bool {
        get {
            if defaults.object(forKey: "aiWebSearchEnabled") == nil { return true }
            return defaults.bool(forKey: "aiWebSearchEnabled")
        }
        set { defaults.set(newValue, forKey: "aiWebSearchEnabled") }
    }

    static var overlayOpacity: Double {
        get {
            let value = defaults.double(forKey: "overlayOpacity")
            return value > 0 ? value : 1.0
        }
        set { defaults.set(newValue, forKey: "overlayOpacity") }
    }

    /// Main window appearance. Follows the system by default; the overlay and notch are always dark.
    static var appTheme: AppTheme.Mode {
        get { AppTheme.Mode(rawValue: defaults.string(forKey: appThemeKey) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: appThemeKey) }
    }

    static let appThemeKey = "appTheme"

    static var hideFromScreenShare: Bool {
        get {
            if defaults.object(forKey: "hideFromScreenShare") == nil { return true }
            return defaults.bool(forKey: "hideFromScreenShare")
        }
        set { defaults.set(newValue, forKey: "hideFromScreenShare") }
    }

    /// When enabled, Meetly prompts for meeting audio capture when a meeting starts.
    static var captureMeetingAudioByDefault: Bool {
        get {
            if defaults.object(forKey: "captureMeetingAudioByDefault") == nil { return true }
            return defaults.bool(forKey: "captureMeetingAudioByDefault")
        }
        set { defaults.set(newValue, forKey: "captureMeetingAudioByDefault") }
    }

    /// When enabled, Meetly offers to record when a call starts in any app or browser.
    static var detectMeetings: Bool {
        get {
            if defaults.object(forKey: "detectMeetings") == nil { return true }
            return defaults.bool(forKey: "detectMeetings")
        }
        set { defaults.set(newValue, forKey: "detectMeetings") }
    }

    /// When enabled, a recording stops after the call it overlapped with ends.
    static var autoStopWhenCallEnds: Bool {
        get {
            if defaults.object(forKey: "autoStopWhenCallEnds") == nil { return true }
            return defaults.bool(forKey: "autoStopWhenCallEnds")
        }
        set { defaults.set(newValue, forKey: "autoStopWhenCallEnds") }
    }

    /// Minutes without speech before a recording stops itself. Zero turns this off.
    static var idleRecordingStopMinutes: Int {
        get {
            if defaults.object(forKey: "idleRecordingStopMinutes") == nil { return 15 }
            return defaults.integer(forKey: "idleRecordingStopMinutes")
        }
        set { defaults.set(newValue, forKey: "idleRecordingStopMinutes") }
    }

    /// Preferred overlay content-area height (listening / transcript scroll region).
    static var overlayContentHeight: Double {
        get {
            let value = defaults.double(forKey: "overlayContentHeight")
            return value > 0 ? value : 80
        }
        set { defaults.set(newValue, forKey: "overlayContentHeight") }
    }
}
