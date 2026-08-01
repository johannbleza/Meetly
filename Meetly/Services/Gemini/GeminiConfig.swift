import Foundation

enum GeminiConfig {
    static let baseURL = "https://generativelanguage.googleapis.com/v1beta"

    static var textModel: String {
        get { AppSettings.geminiTextModel }
        set { AppSettings.geminiTextModel = newValue }
    }

    static var hasAPIKey: Bool {
        guard let key = resolvedAPIKey else { return false }
        return !key.isEmpty && key != "<your-key-here>" && key != "YOUR_GEMINI_API_KEY"
    }

    static func apiKey() throws -> String {
        guard let key = resolvedAPIKey else {
            throw GeminiError.missingAPIKey
        }
        return key
    }

    private static var resolvedAPIKey: String? {
        if let key = GeminiKeyStore.apiKey {
            return key
        }
        return DotEnv.value(for: "GEMINI_API_KEY")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func generateContentURL(model: String) throws -> URL {
        let key = try apiKey()
        guard let url = URL(string: "\(baseURL)/models/\(model):generateContent?key=\(key)") else {
            throw GeminiError.invalidURL
        }
        return url
    }
}

enum GeminiError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case invalidResponse
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add your Gemini API key in Settings."
        case .invalidURL:
            "Invalid Gemini API URL."
        case .invalidResponse:
            "Unexpected response from Gemini."
        case .apiError(let message):
            message
        }
    }
}
