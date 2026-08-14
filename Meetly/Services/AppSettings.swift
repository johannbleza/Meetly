import Foundation

enum AppSettings {
    private static let defaults = UserDefaults.standard
    private static let defaultTextModel = "gemini-2.5-flash"

    static var aiProvider: AIProvider {
        get {
            guard let rawValue = defaults.string(forKey: "aiProvider"),
                  let provider = AIProvider(rawValue: rawValue) else {
                return .appleIntelligence
            }
            return provider
        }
        set { defaults.set(newValue.rawValue, forKey: "aiProvider") }
    }

    static var geminiTextModel: String {
        get { defaults.string(forKey: "geminiTextModel") ?? defaultTextModel }
        set { defaults.set(newValue, forKey: "geminiTextModel") }
    }

    /// When enabled, Gemini Q&A may use Google Search for questions that need current or external knowledge.
    static var geminiWebSearchEnabled: Bool {
        get {
            if defaults.object(forKey: "geminiWebSearchEnabled") == nil { return true }
            return defaults.bool(forKey: "geminiWebSearchEnabled")
        }
        set { defaults.set(newValue, forKey: "geminiWebSearchEnabled") }
    }

    static var overlayOpacity: Double {
        get {
            let value = defaults.double(forKey: "overlayOpacity")
            return value > 0 ? value : 1.0
        }
        set { defaults.set(newValue, forKey: "overlayOpacity") }
    }

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

    /// When enabled, speech that the mic picks up from speakers is not labeled as you.
    static var reduceSpeakerBleed: Bool {
        get {
            if defaults.object(forKey: "reduceSpeakerBleed") == nil { return true }
            return defaults.bool(forKey: "reduceSpeakerBleed")
        }
        set { defaults.set(newValue, forKey: "reduceSpeakerBleed") }
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
