import Foundation

struct GeminiRESTClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static var isAvailable: Bool {
        GeminiConfig.hasAPIKey
    }

    static var availabilityMessage: String? {
        guard !GeminiConfig.hasAPIKey else { return nil }
        return "Add your Gemini API key in Settings."
    }

    func testConnection() async throws {
        _ = try await generateText(
            prompt: "Reply with exactly: OK",
            systemInstruction: "Reply briefly."
        )
    }

    func answerQuestion(transcript: String, question: String) async throws -> String {
        let context = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt: String
        if context.isEmpty {
            prompt = """
            No meeting transcript has been captured yet.

            User question:
            \(question)

            Tell the user you're still listening and no speech has been transcribed yet. \
            Suggest they speak clearly into the microphone and wait a few seconds before asking again.
            """
        } else {
            prompt = """
            Meeting transcript:
            \(context)

            User question:
            \(question)

            Answer the question using only the transcript context. Be concise.
            """
        }
        return try await generateText(
            prompt: prompt,
            systemInstruction: "You are a meeting assistant. Answer questions based on the meeting transcript."
        )
    }

    func generateSummary(from transcript: String) async throws -> SummaryOutput {
        let prompt = """
        Summarize this meeting transcript. Return JSON with keys:
        title, summary, keyPoints (array of strings), actionItems (array of strings).

        Transcript:
        \(transcript)
        """
        let json = try await generateJSON(
            prompt: prompt,
            systemInstruction: "You are a meeting assistant. Produce accurate meeting summaries."
        )
        let data = Data(json.utf8)
        return try JSONDecoder().decode(SummaryOutput.self, from: data)
    }

    private func generateText(prompt: String, systemInstruction: String) async throws -> String {
        let url = try GeminiConfig.generateContentURL(model: GeminiConfig.textModel)
        let body = GenerateContentRequest(
            systemInstruction: SystemInstruction(parts: [Part(text: systemInstruction)]),
            contents: [Content(role: "user", parts: [Part(text: prompt)])]
        )

        let response: GenerateContentResponse = try await post(url: url, body: body)
        guard let text = response.candidates?.first?.content?.parts.first?.text else {
            throw GeminiError.invalidResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func generateJSON(prompt: String, systemInstruction: String) async throws -> String {
        let url = try GeminiConfig.generateContentURL(model: GeminiConfig.textModel)
        let body = GenerateContentRequest(
            systemInstruction: SystemInstruction(parts: [Part(text: systemInstruction)]),
            contents: [Content(role: "user", parts: [Part(text: prompt)])],
            generationConfig: GenerationConfig(responseMimeType: "application/json")
        )

        let response: GenerateContentResponse = try await post(url: url, body: body)
        guard let text = response.candidates?.first?.content?.parts.first?.text else {
            throw GeminiError.invalidResponse
        }
        return text
    }

    private func post<T: Encodable, R: Decodable>(url: URL, body: T) async throws -> R {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }

        if http.statusCode != 200 {
            if let apiError = try? JSONDecoder().decode(GeminiAPIErrorResponse.self, from: data) {
                throw GeminiError.apiError(apiError.error.message)
            }
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw GeminiError.apiError(body)
        }

        return try JSONDecoder().decode(R.self, from: data)
    }
}

private struct GenerateContentRequest: Encodable {
    var systemInstruction: SystemInstruction?
    var contents: [Content]
    var generationConfig: GenerationConfig?
}

private struct SystemInstruction: Encodable {
    var parts: [Part]
}

private struct Content: Encodable {
    var role: String
    var parts: [Part]
}

private struct Part: Encodable {
    var text: String?

    init(text: String) {
        self.text = text
    }
}

private struct GenerationConfig: Encodable {
    var responseMimeType: String
}

private struct GenerateContentResponse: Decodable {
    var candidates: [Candidate]?
}

private struct Candidate: Decodable {
    var content: ResponseContent?
}

private struct ResponseContent: Decodable {
    var parts: [ResponsePart]
}

private struct ResponsePart: Decodable {
    var text: String?
}

private struct GeminiAPIErrorResponse: Decodable {
    var error: GeminiAPIError
}

private struct GeminiAPIError: Decodable {
    var message: String
}
