import Foundation

@MainActor
final class AIService {
    private let foundationClient = FoundationModelsClient()

    var provider: AIProvider {
        AppSettings.aiProvider
    }

    var isAvailable: Bool {
        if let agent = provider.cliAgent {
            return agent.isInstalled
        }
        return FoundationModelsClient.isAvailable
    }

    var availabilityMessage: String? {
        if let agent = provider.cliAgent {
            return agent.isInstalled ? nil : agent.setupMessage
        }
        return FoundationModelsClient.availabilityMessage
    }

    /// The on-device model can't read images, so those use whichever installed tool is available.
    var imageAgent: CLIAgent? {
        if let agent = provider.cliAgent {
            return agent.isInstalled ? agent : nil
        }
        return CLIAgent.allCases.first(where: \.isInstalled)
    }

    func answerQuestion(
        transcript: String,
        question: String,
        images: [ChatImageAttachment] = [],
        conversationHistory: String? = nil
    ) async throws -> String {
        if !images.isEmpty {
            guard let agent = imageAgent else {
                throw AIError.unavailable(Self.imagesUnavailableMessage)
            }
            return try await CLIAgentClient(agent: agent).answerQuestion(
                transcript: transcript,
                question: question,
                images: images,
                conversationHistory: conversationHistory
            )
        }
        if let agent = provider.cliAgent {
            return try await CLIAgentClient(agent: agent).answerQuestion(
                transcript: transcript,
                question: question,
                conversationHistory: conversationHistory
            )
        }
        return try await foundationClient.answerQuestion(
            transcript: transcript,
            question: question,
            conversationHistory: conversationHistory
        )
    }

    func generateSummary(from transcript: String) async throws -> SummaryOutput {
        if let agent = provider.cliAgent {
            return try await CLIAgentClient(agent: agent).generateSummary(from: transcript)
        }
        return try await foundationClient.generateSummary(from: transcript)
    }

    func generateActionItems(from context: String) async throws -> [String] {
        if let agent = provider.cliAgent {
            return try await CLIAgentClient(agent: agent).generateActionItems(from: context)
        }
        return try await foundationClient.generateActionItems(from: context)
    }

    func testConnection() async throws {
        if let agent = provider.cliAgent {
            try await CLIAgentClient(agent: agent).testConnection()
        } else {
            try await foundationClient.testConnection()
        }
    }

    static let imagesUnavailableMessage = "Install and sign in to Claude Code or Codex to ask about images."
}
