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

    func answerQuestion(transcript: String, question: String, images: [ChatImageAttachment]) async throws -> String {
        let context = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageLabel = images.count > 1 ? "Images are attached" : "An image is attached"
        let imageInstruction = images.count > 1
            ? "Use the attached images to answer the user's question."
            : "Use the image to answer the user's question."
        let prompt: String
        if context.isEmpty {
            prompt = """
            No meeting transcript has been captured yet.

            \(imageLabel). \(imageInstruction)

            User question:
            \(question)

            If the question depends on meeting context, tell the user you're still listening and no speech has been transcribed yet. \
            Otherwise answer based on the \(images.count > 1 ? "images" : "image") alone. \
            Respond in plain text only — no markdown, bullet lists, headers, or other formatting.
            """
        } else {
            prompt = """
            Meeting transcript:
            \(context)

            \(imageLabel). Use both the meeting transcript and the \(images.count > 1 ? "images" : "image") to answer the user's question.

            User question:
            \(question)

            Be concise. Respond in plain text only — no markdown, bullet lists, headers, or other formatting.
            """
        }

        var parts: [Part] = [Part(text: prompt)]
        for image in images {
            parts.append(Part(imageData: image.data, mimeType: image.mimeType))
        }

        return try await generateMultimodalText(
            parts: parts,
            systemInstruction: """
            You are a meeting assistant. Answer questions using meeting transcript context and any attached images. \
            Always respond in plain text. Never use markdown or other text formatting.
            """
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
            Suggest they speak clearly into the microphone and wait a few seconds before asking again. \
            Respond in plain text only — no markdown, bullet lists, headers, or other formatting.
            """
        } else {
            prompt = """
            Meeting transcript:
            \(context)

            User question:
            \(question)

            Answer the question using only the transcript context. Be concise. \
            Respond in plain text only — no markdown, bullet lists, headers, or other formatting.
            """
        }
        return try await generateText(
            prompt: prompt,
            systemInstruction: """
            You are a meeting assistant. Answer questions based on the meeting transcript. \
            Always respond in plain text. Never use markdown or other text formatting.
            """
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

    func generateActionItems(from context: String) async throws -> [String] {
        let prompt = """
        Extract concrete action items and follow-up tasks from this meeting content. \
        Return JSON with key actionItems (array of strings). Each item should be a clear, actionable task.

        Meeting content:
        \(context)
        """
        let json = try await generateJSON(
            prompt: prompt,
            systemInstruction: "You are a meeting assistant. Extract actionable follow-up tasks."
        )
        let data = Data(json.utf8)
        let output = try JSONDecoder().decode(ActionItemsOutput.self, from: data)
        return output.actionItems
    }

    private func generateMultimodalText(parts: [Part], systemInstruction: String) async throws -> String {
        let url = try GeminiConfig.generateContentURL(model: GeminiConfig.textModel)
        let body = GenerateContentRequest(
            systemInstruction: SystemInstruction(parts: [Part(text: systemInstruction)]),
            contents: [Content(role: "user", parts: parts)]
        )

        let response: GenerateContentResponse = try await post(url: url, body: body)
        guard let text = response.candidates?.first?.content?.parts.first?.text else {
            throw GeminiError.invalidResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
    var inlineData: InlineData?

    init(text: String) {
        self.text = text
        self.inlineData = nil
    }

    init(imageData: Data, mimeType: String) {
        self.text = nil
        self.inlineData = InlineData(mimeType: mimeType, data: imageData.base64EncodedString())
    }

    struct InlineData: Encodable {
        var mimeType: String
        var data: String
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
