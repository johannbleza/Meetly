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

    static var overlayOpacity: Double {
        get {
            let value = defaults.double(forKey: "overlayOpacity")
            return value > 0 ? value : 1.0
        }
        set { defaults.set(newValue, forKey: "overlayOpacity") }
    }
}
