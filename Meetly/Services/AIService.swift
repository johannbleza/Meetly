import Foundation

@MainActor
final class AIService {
    private let foundationClient = FoundationModelsClient()
    private let geminiClient = GeminiRESTClient()

    var provider: AIProvider {
        AppSettings.aiProvider
    }

    var isAvailable: Bool {
        switch provider {
        case .appleIntelligence:
            FoundationModelsClient.isAvailable
        case .gemini:
            GeminiRESTClient.isAvailable
        }
    }

    var availabilityMessage: String? {
        switch provider {
        case .appleIntelligence:
            FoundationModelsClient.availabilityMessage
        case .gemini:
            GeminiRESTClient.availabilityMessage
        }
    }

    func answerQuestion(transcript: String, question: String) async throws -> String {
        switch provider {
        case .appleIntelligence:
            try await foundationClient.answerQuestion(transcript: transcript, question: question)
        case .gemini:
            try await geminiClient.answerQuestion(transcript: transcript, question: question)
        }
    }

    func generateSummary(from transcript: String) async throws -> SummaryOutput {
        switch provider {
        case .appleIntelligence:
            try await foundationClient.generateSummary(from: transcript)
        case .gemini:
            try await geminiClient.generateSummary(from: transcript)
        }
    }

    func generateActionItems(from context: String) async throws -> [String] {
        switch provider {
        case .appleIntelligence:
            try await foundationClient.generateActionItems(from: context)
        case .gemini:
            try await geminiClient.generateActionItems(from: context)
        }
    }

    func testConnection() async throws {
        switch provider {
        case .appleIntelligence:
            try await foundationClient.testConnection()
        case .gemini:
            try await geminiClient.testConnection()
        }
    }
}
