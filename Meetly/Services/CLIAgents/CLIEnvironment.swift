import Foundation

/// Finds command-line tools and builds their environment. Apps launched from Finder get a minimal
/// PATH, so it is rebuilt from common install locations plus the user's login shell.
nonisolated enum CLIEnvironment {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var shellPathDirectories: [String]?

    /// Keys that would bill an API account instead of the signed-in subscription, or make a
    /// child tool think it is nested inside another agent session.
    private static let strippedVariables: Set<String> = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
        "OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_API_KEY",
        "CLAUDECODE",
    ]
    private static let strippedPrefixes = ["CLAUDE_CODE_", "DYLD_", "__XPC_"]

    private static var commonDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin",
            "\(home)/.claude/local",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "/usr/bin",
            "/bin",
        ]
    }

    private static var searchDirectories: [String] {
        lock.lock()
        let fromShell = shellPathDirectories ?? []
        lock.unlock()

        var seen = Set<String>()
        return (commonDirectories + fromShell).filter { seen.insert($0).inserted }
    }

    static func locate(_ command: String) -> URL? {
        for directory in searchDirectories {
            let path = "\(directory)/\(command)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !strippedVariables.contains(key) && !strippedPrefixes.contains { key.hasPrefix($0) }
        }
        environment["PATH"] = searchDirectories.joined(separator: ":")
        environment["NO_COLOR"] = "1"
        // Claude Code looks up its Keychain sign-in by user name.
        environment["USER"] = NSUserName()
        return environment
    }

    /// Picks up version-manager installs (nvm and friends) that only the user's shell knows about.
    /// Interactive because those managers usually hook in from `.zshrc`.
    static func loadShellPathIfNeeded() async {
        let alreadyLoaded = lock.withLock { shellPathDirectories != nil }
        guard !alreadyLoaded else { return }

        let marker = "__MEETLY_PATH__"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var directories: [String] = []
        if let result = try? await CLIProcessRunner.run(
            executable: URL(fileURLWithPath: shell),
            arguments: ["-ilc", "printf '\(marker)%s' \"$PATH\""],
            environment: ProcessInfo.processInfo.environment,
            timeout: 5
        ), let output = String(data: result.stdout, encoding: .utf8),
           let range = output.range(of: marker, options: .backwards) {
            directories = output[range.upperBound...]
                .split(separator: ":")
                .map(String.init)
        }

        lock.withLock { shellPathDirectories = directories }
    }
}
