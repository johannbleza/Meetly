import Foundation

enum AIProvider: String, CaseIterable, Identifiable {
    case appleIntelligence
    case gemini

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleIntelligence:
            "Apple Intelligence"
        case .gemini:
            "Gemini"
        }
    }

    var settingsDescription: String {
        switch self {
        case .appleIntelligence:
            "Runs on-device with Apple Intelligence. No API key required."
        case .gemini:
            "Uses Google's Gemini API over the internet. Requires an API key."
        }
    }
}
