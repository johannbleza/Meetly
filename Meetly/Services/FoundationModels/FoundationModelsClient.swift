import Foundation
import FoundationModels

enum AIError: LocalizedError {
    case unavailable(String)
    case invalidResponse
    case contextExceeded

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            message
        case .invalidResponse:
            "Unexpected response from the on-device model."
        case .contextExceeded:
            "The meeting transcript is too long to summarize on-device."
        }
    }
}

@MainActor
struct FoundationModelsClient {
    private static let meetingAssistantInstructions =
        "You are a meeting assistant. Answer questions based on the meeting transcript."

    /// Permissive guardrails for summarizing user-provided meeting transcripts.
    private static let meetingModel = SystemLanguageModel(
        guardrails: .permissiveContentTransformations
    )

    private func makeSession(instructions: String) -> LanguageModelSession {
        LanguageModelSession(model: Self.meetingModel, instructions: instructions)
    }

    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    static var availabilityMessage: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Enable Apple Intelligence in System Settings to use AI features."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading. Try again shortly."
        case .unavailable:
            return "Apple Intelligence is unavailable on this Mac."
        }
    }

    func testConnection() async throws {
        try ensureAvailable()
        let session = makeSession(instructions: "Reply briefly.")
        let response = try await session.respond(to: "Reply with exactly: OK")
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text == "OK" else {
            throw AIError.invalidResponse
        }
    }

    func answerQuestion(transcript: String, question: String) async throws -> String {
        try ensureAvailable()
        let trimmedTranscript = TranscriptTrimmer.recentLines(
            from: TranscriptTrimmer.trimToCharacterLimit(transcript)
        )
        let prompt = questionPrompt(transcript: trimmedTranscript, question: question)
        let session = makeSession(instructions: Self.meetingAssistantInstructions)
        let response = try await session.respond(to: prompt)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func generateSummary(from transcript: String) async throws -> SummaryOutput {
        try ensureAvailable()
        let trimmed = TranscriptTrimmer.trimToCharacterLimit(transcript)
        return try await generateSummary(from: trimmed, allowRetry: true)
    }

    func generateActionItems(from context: String) async throws -> [String] {
        try ensureAvailable()
        let trimmed = TranscriptTrimmer.trimToCharacterLimit(context)
        let prompt = """
        Extract concrete action items and follow-up tasks from this meeting content. \
        Return JSON with key actionItems (array of strings). Each item should be a clear, actionable task.

        Meeting content:
        \(trimmed)
        """
        let session = makeSession(
            instructions: "You are a meeting assistant. Extract actionable follow-up tasks."
        )
        let response = try await session.respond(to: prompt)
        let json = Self.extractJSON(from: response.content)
        let data = Data(json.utf8)
        let output = try JSONDecoder().decode(ActionItemsOutput.self, from: data)
        return output.actionItems
    }

    private func generateSummary(from transcript: String, allowRetry: Bool) async throws -> SummaryOutput {
        let prompt = """
        Summarize this meeting transcript. Return JSON with keys:
        title, summary, keyPoints (array of strings), actionItems (array of strings).

        Transcript:
        \(transcript)
        """
        let session = makeSession(
            instructions: "You are a meeting assistant. Produce accurate meeting summaries."
        )

        do {
            let response = try await session.respond(to: prompt)
            let json = Self.extractJSON(from: response.content)
            let data = Data(json.utf8)
            return try JSONDecoder().decode(SummaryOutput.self, from: data)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            guard allowRetry else { throw AIError.contextExceeded }
            let half = TranscriptTrimmer.secondHalf(of: transcript)
            guard half != transcript, !half.isEmpty else {
                throw AIError.contextExceeded
            }
            return try await generateSummary(from: half, allowRetry: false)
        } catch {
            return Self.fallbackSummary(from: transcript)
        }
    }

    private static func extractJSON(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    private static func fallbackSummary(from transcript: String) -> SummaryOutput {
        let lines = transcript
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let preview = lines.prefix(3).joined(separator: " ")
        return SummaryOutput(
            title: "Meeting",
            summary: preview.isEmpty ? "Meeting recorded." : preview,
            keyPoints: [],
            actionItems: []
        )
    }

    private func ensureAvailable() throws {
        if let message = Self.availabilityMessage {
            throw AIError.unavailable(message)
        }
    }

    private func questionPrompt(transcript: String, question: String) -> String {
        let context = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if context.isEmpty {
            return """
            No meeting transcript has been captured yet.

            User question:
            \(question)

            Tell the user you're still listening and no speech has been transcribed yet. \
            Suggest they speak clearly into the microphone and wait a few seconds before asking again.
            """
        }

        return """
        Meeting transcript:
        \(context)

        User question:
        \(question)

        Answer the question using only the transcript context. Be concise.
        """
    }
}
