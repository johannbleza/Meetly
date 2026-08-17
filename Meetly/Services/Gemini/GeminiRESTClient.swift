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
            systemInstruction: "Reply briefly.",
            enableWebSearch: false
        )
    }

    func answerQuestion(
        transcript: String,
        question: String,
        images: [ChatImageAttachment],
        conversationHistory: String? = nil
    ) async throws -> String {
        let context = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let webSearch = AppSettings.geminiWebSearchEnabled
        let imageLabel = images.count > 1 ? "Images are attached" : "An image is attached"
        let imageInstruction = images.count > 1
            ? "Use the attached images to answer the user's question."
            : "Use the image to answer the user's question."
        let historyBlock = MeetingContextBuilder.conversationHistoryPromptBlock(conversationHistory)
        let prompt: String
        if context.isEmpty {
            prompt = """
            No meeting transcript has been captured yet.
            \(historyBlock)

            \(imageLabel). \(imageInstruction)

            User question:
            \(question)

            \(emptyTranscriptGuidance(webSearchEnabled: webSearch, imageFallback: images.count > 1 ? "images" : "image"))
            Respond in plain text only — no markdown, bullet lists, headers, or other formatting.
            """
        } else {
            prompt = """
            Meeting transcript:
            \(context)
            \(historyBlock)

            \(imageLabel). Prefer the meeting transcript and the \(images.count > 1 ? "images" : "image") when they answer the question.

            User question:
            \(question)

            \(webSearchGuidance(enabled: webSearch))
            Be concise. Respond in plain text only — no markdown, bullet lists, headers, or other formatting.
            """
        }

        var parts: [Part] = [Part(text: prompt)]
        for image in images {
            parts.append(Part(imageData: image.data, mimeType: image.mimeType))
        }

        return try await generateMultimodalText(
            parts: parts,
            systemInstruction: qaSystemInstruction(webSearchEnabled: webSearch, includesImages: true),
            enableWebSearch: webSearch
        )
    }

    func answerQuestion(
        transcript: String,
        question: String,
        conversationHistory: String? = nil
    ) async throws -> String {
        let context = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let webSearch = AppSettings.geminiWebSearchEnabled
        let historyBlock = MeetingContextBuilder.conversationHistoryPromptBlock(conversationHistory)
        let prompt: String
        if context.isEmpty {
            prompt = """
            No meeting transcript has been captured yet.
            \(historyBlock)

            User question:
            \(question)

            \(emptyTranscriptGuidance(webSearchEnabled: webSearch, imageFallback: nil))
            Respond in plain text only — no markdown, bullet lists, headers, or other formatting.
            """
        } else {
            prompt = """
            Meeting transcript:
            \(context)
            \(historyBlock)

            User question:
            \(question)

            Prefer the meeting transcript when it answers the question. \
            \(webSearchGuidance(enabled: webSearch))
            Be concise. Respond in plain text only — no markdown, bullet lists, headers, or other formatting.
            """
        }
        return try await generateText(
            prompt: prompt,
            systemInstruction: qaSystemInstruction(webSearchEnabled: webSearch, includesImages: false),
            enableWebSearch: webSearch
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

    private func qaSystemInstruction(webSearchEnabled: Bool, includesImages: Bool) -> String {
        let sources: String
        if includesImages && webSearchEnabled {
            sources = "meeting transcript context, attached images, and web search when needed"
        } else if includesImages {
            sources = "meeting transcript context and any attached images"
        } else if webSearchEnabled {
            sources = "meeting transcript context, and web search when the question needs current or external knowledge"
        } else {
            sources = "the meeting transcript"
        }

        return """
        You are a meeting assistant. Answer questions using \(sources). \
        If the user asks a follow-up, use the previous conversation in this chat together with those sources. \
        Always respond in plain text. Never use markdown or other text formatting.
        """
    }

    private func webSearchGuidance(enabled: Bool) -> String {
        guard enabled else {
            return "Answer using only the provided meeting context."
        }
        return """
        If the question needs current facts, definitions, or knowledge outside the transcript, use web search. \
        Otherwise answer from the meeting context alone.
        """
    }

    private func emptyTranscriptGuidance(webSearchEnabled: Bool, imageFallback: String?) -> String {
        if webSearchEnabled {
            let fallbackClause: String
            if let imageFallback {
                fallbackClause = "using the \(imageFallback) and web search as needed"
            } else {
                fallbackClause = "using web search as needed"
            }
            return """
            If the question depends on meeting context, tell the user you're still listening and no speech has been transcribed yet. \
            If the question can be answered without meeting context, answer it \(fallbackClause).
            """
        }

        if let imageFallback {
            return """
            If the question depends on meeting context, tell the user you're still listening and no speech has been transcribed yet. \
            Otherwise answer based on the \(imageFallback) alone.
            """
        }

        return """
        Tell the user you're still listening and no speech has been transcribed yet. \
        Suggest they speak clearly into the microphone and wait a few seconds before asking again.
        """
    }

    private func generateMultimodalText(
        parts: [Part],
        systemInstruction: String,
        enableWebSearch: Bool
    ) async throws -> String {
        let url = try GeminiConfig.generateContentURL(model: GeminiConfig.textModel)
        let body = GenerateContentRequest(
            systemInstruction: SystemInstruction(parts: [Part(text: systemInstruction)]),
            contents: [Content(role: "user", parts: parts)],
            tools: enableWebSearch ? [.googleSearchTool] : nil
        )

        let response: GenerateContentResponse = try await post(url: url, body: body)
        guard let text = response.candidates?.first?.content?.parts.first?.text else {
            throw GeminiError.invalidResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func generateText(
        prompt: String,
        systemInstruction: String,
        enableWebSearch: Bool
    ) async throws -> String {
        let url = try GeminiConfig.generateContentURL(model: GeminiConfig.textModel)
        let body = GenerateContentRequest(
            systemInstruction: SystemInstruction(parts: [Part(text: systemInstruction)]),
            contents: [Content(role: "user", parts: [Part(text: prompt)])],
            tools: enableWebSearch ? [.googleSearchTool] : nil
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
    var tools: [Tool]?
}

private struct Tool: Encodable {
    var googleSearch: EmptyObject?

    static let googleSearchTool = Tool(googleSearch: EmptyObject())

    enum CodingKeys: String, CodingKey {
        case googleSearch = "google_search"
    }
}

private struct EmptyObject: Encodable {}

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
