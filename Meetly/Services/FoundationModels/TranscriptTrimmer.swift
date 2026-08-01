import Foundation

enum TranscriptTrimmer {
    static func recentLines(from transcript: String, maxLines: Int = 60) -> String {
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return transcript }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    static func secondHalf(of transcript: String) -> String {
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return transcript }
        return lines.suffix(lines.count / 2).joined(separator: "\n")
    }

    static func trimToCharacterLimit(_ text: String, maxCharacters: Int = 12_000) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.suffix(maxCharacters))
    }
}
