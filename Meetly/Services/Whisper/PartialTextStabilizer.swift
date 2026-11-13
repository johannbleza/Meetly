import Foundation

/// Keeps Whisper's live captions readable. Each partial re-decodes the whole utterance, so
/// its wording changes between decodes; only words two decodes in a row agree on are shown.
/// The caption therefore grows at the end instead of rewriting itself.
nonisolated struct PartialTextStabilizer {
    private var previousWords: [String] = []
    private var shownWords: [String] = []

    /// Returns the caption to show if it changed, or nil if it should stay as it is.
    mutating func update(with decoded: String) -> String? {
        let words = decoded.split(whereSeparator: \.isWhitespace).map(String.init)
        defer { previousWords = words }

        var agreed = 0
        while agreed < min(words.count, previousWords.count),
              Self.normalized(words[agreed]) == Self.normalized(previousWords[agreed]) {
            agreed += 1
        }

        // Never shrink: a decode that drops words is usually wrong, and the final decode settles it.
        guard agreed > shownWords.count else { return nil }
        shownWords = Array(words[..<agreed])
        return shownWords.joined(separator: " ")
    }

    mutating func reset() {
        previousWords = []
        shownWords = []
    }

    /// Case and punctuation shift as a sentence grows ("today." then "today,"); the word hasn't changed.
    private static func normalized(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
