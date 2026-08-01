import Foundation

enum DotEnv {
    private static var cached: [String: String]?
    private static let lock = NSLock()

    static func value(for key: String) -> String? {
        if let env = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }

        lock.lock()
        defer { lock.unlock() }

        if cached == nil {
            cached = load()
        }
        return cached?[key]
    }

    private static func load() -> [String: String] {
        for url in candidateURLs() {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            return parse(contents)
        }
        return [:]
    }

    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        urls.append(cwd.appendingPathComponent(".env"))

        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            urls.append(directory.appendingPathComponent(".env"))
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path {
                break
            }
            directory = parent
        }

        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent(".env"))
        }

        return urls
    }

    private static func parse(_ contents: String) -> [String: String] {
        var values: [String: String] = [:]

        for line in contents.split(whereSeparator: \.isNewline) {
            var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            if trimmed.hasPrefix("export ") {
                trimmed.removeFirst(7)
            }
            guard let separator = trimmed.firstIndex(of: "=") else {
                continue
            }

            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }

            if !key.isEmpty {
                values[key] = value
            }
        }

        return values
    }

    static func value(for key: String, in contents: String) -> String? {
        parse(contents)[key]
    }
}
