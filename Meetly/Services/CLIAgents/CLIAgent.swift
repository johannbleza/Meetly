import Foundation

enum CLIAgentError: LocalizedError {
    case notInstalled(CLIAgent)
    case failed(String)
    case invalidResponse(CLIAgent)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let agent):
            agent.setupMessage
        case .failed(let message):
            message
        case .invalidResponse(let agent):
            "Unexpected response from \(agent.label)."
        }
    }
}

/// An official AI command-line tool that is signed in to the user's own subscription.
///
/// Meeting transcripts are untrusted input: anyone on a call can speak instructions into them.
/// So each invocation must keep shell and file tools off and ignore the user's settings, MCP
/// servers, and hooks, and must not save the conversation to the tool's history.
enum CLIAgent: String, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    var command: String { rawValue }

    var isInstalled: Bool {
        CLIEnvironment.locate(command) != nil
    }

    var setupMessage: String {
        switch self {
        case .claude:
            "Install Claude Code, then run `claude` in Terminal once to sign in."
        case .codex:
            "Install the Codex CLI, then run `codex login` in Terminal to sign in."
        }
    }

    var model: String {
        switch self {
        case .claude: AppSettings.claudeModel
        case .codex: AppSettings.codexModel
        }
    }

    struct Request {
        var prompt: String
        var systemPrompt: String
        var images: [ChatImageAttachment] = []
        var allowsWebSearch = false
        var timeout: TimeInterval
    }

    func respond(to request: Request) async throws -> String {
        await CLIEnvironment.loadShellPathIfNeeded()
        guard let executable = CLIEnvironment.locate(command) else {
            throw CLIAgentError.notInstalled(self)
        }

        // An empty, disposable working directory keeps project files and instructions out of reach.
        let workingDirectory = FileManager.default.temporaryDirectory
            .appending(path: "MeetlyAI-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        switch self {
        case .claude:
            return try await respondWithClaude(request, executable: executable, workingDirectory: workingDirectory)
        case .codex:
            return try await respondWithCodex(request, executable: executable, workingDirectory: workingDirectory)
        }
    }

    // MARK: - Claude Code

    private func respondWithClaude(
        _ request: Request,
        executable: URL,
        workingDirectory: URL
    ) async throws -> String {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--system-prompt", request.systemPrompt,
            "--setting-sources", "",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--no-session-persistence",
        ]
        if request.allowsWebSearch {
            arguments += ["--tools", "WebSearch", "--allowedTools", "WebSearch"]
        } else {
            arguments += ["--tools", ""]
        }
        if !model.isEmpty {
            arguments += ["--model", model]
        }

        let result = try await CLIProcessRunner.run(
            executable: executable,
            arguments: arguments,
            environment: CLIEnvironment.processEnvironment(),
            workingDirectory: workingDirectory,
            input: try Self.claudeInput(prompt: request.prompt, images: request.images),
            timeout: request.timeout
        )

        // The final JSONL record carries the answer, or the error text such as a login prompt.
        let finalRecord = String(decoding: result.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .reversed()
            .lazy
            .compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            }
            .first { $0["type"] as? String == "result" }

        if let finalRecord {
            let text = (finalRecord["result"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if finalRecord["is_error"] as? Bool == true {
                throw CLIAgentError.failed(text.isEmpty ? Self.failureMessage(from: result, agent: self) : text)
            }
            if !text.isEmpty {
                return text
            }
        }
        if result.exitCode != 0 {
            throw CLIAgentError.failed(Self.failureMessage(from: result, agent: self))
        }
        throw CLIAgentError.invalidResponse(self)
    }

    private static func claudeInput(prompt: String, images: [ChatImageAttachment]) throws -> Data {
        var content: [[String: Any]] = images.map { image in
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": image.mimeType,
                    "data": image.data.base64EncodedString(),
                ],
            ]
        }
        content.append(["type": "text", "text": prompt])

        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content],
        ]
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        return data
    }

    // MARK: - Codex

    private func respondWithCodex(
        _ request: Request,
        executable: URL,
        workingDirectory: URL
    ) async throws -> String {
        let outputFile = workingDirectory.appending(path: "answer.txt")
        var arguments = [
            "exec",
            "--sandbox", "read-only",
            "--skip-git-repo-check",
            "--ephemeral",
            "--color", "never",
            "--ignore-user-config",
            "--ignore-rules",
            "--disable", "shell_tool",
            "--disable", "hooks",
            "--disable", "plugins",
            "--disable", "memories",
            "--disable", "image_generation",
            "--disable", "skill_search",
            "-c", "project_doc_max_bytes=0",
            "-c", "model_reasoning_effort=\"low\"",
            "-c", "web_search=\"\(request.allowsWebSearch ? "live" : "disabled")\"",
            "-c", "developer_instructions=\(try Self.tomlString(request.systemPrompt))",
        ]
        if !model.isEmpty {
            arguments += ["--model", model]
        }
        for (index, image) in request.images.enumerated() {
            let imageFile = workingDirectory.appending(path: "image-\(index).\(Self.fileExtension(for: image.mimeType))")
            try image.data.write(to: imageFile)
            arguments += ["--image", imageFile.path]
        }
        // `--image` takes multiple values, so another option has to separate it from the stdin marker.
        arguments += ["--output-last-message", outputFile.path, "-"]

        let result = try await CLIProcessRunner.run(
            executable: executable,
            arguments: arguments,
            environment: CLIEnvironment.processEnvironment(),
            workingDirectory: workingDirectory,
            input: Data(request.prompt.utf8),
            timeout: request.timeout
        )

        if result.exitCode != 0 {
            throw CLIAgentError.failed(Self.failureMessage(from: result, agent: self))
        }
        let text = (try? String(contentsOf: outputFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw CLIAgentError.invalidResponse(self)
        }
        return text
    }

    /// JSON string syntax is valid TOML once slashes are left unescaped.
    private static func tomlString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private static func fileExtension(for mimeType: String) -> String {
        switch mimeType {
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/webp": "webp"
        default: "jpg"
        }
    }

    // MARK: - Errors

    private static func failureMessage(from result: CLIProcessResult, agent: CLIAgent) -> String {
        let lines = String(decoding: result.stderr, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Codex reports API failures as `ERROR: {json}`; show the message inside, not the JSON.
        if let errorLine = lines.last(where: { $0.hasPrefix("ERROR:") }) {
            let payload = errorLine.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces)
            if let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
               let error = object["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            return String(payload.prefix(300))
        }
        if let last = lines.last {
            return String(last.prefix(300))
        }
        return "\(agent.label) exited with an error. \(agent.setupMessage)"
    }
}
