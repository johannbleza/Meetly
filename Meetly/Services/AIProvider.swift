import Foundation

enum AIProvider: String, CaseIterable, Identifiable {
    case claude
    case codex
    case appleIntelligence

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude:
            "Claude"
        case .codex:
            "Codex"
        case .appleIntelligence:
            "Apple Intelligence"
        }
    }

    var settingsDescription: String {
        switch self {
        case .claude:
            "Uses your Claude subscription through the Claude Code command-line tool. Transcripts and questions are sent to Anthropic."
        case .codex:
            "Uses your ChatGPT subscription through the Codex command-line tool. Transcripts and questions are sent to OpenAI."
        case .appleIntelligence:
            "Runs on-device with Apple Intelligence. Can't read images, so those go to Claude or Codex if installed."
        }
    }

    /// The command-line tool behind this provider, if it isn't on-device.
    var cliAgent: CLIAgent? {
        switch self {
        case .claude:
            .claude
        case .codex:
            .codex
        case .appleIntelligence:
            nil
        }
    }
}
