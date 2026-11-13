import Foundation

/// Recognizes mic transcripts that are really meeting audio picked up from the speakers.
///
/// Compares whole transcripts rather than gating audio: gating buffers by level also cuts
/// the user's own speech whenever both sides talk. Word order must match, so ordinary
/// replies that merely share common words with the meeting audio are kept.
nonisolated struct MicBleedFilter {
    struct Configuration {
        /// How long meeting audio stays eligible to explain a mic transcript.
        var window: TimeInterval = 10
        /// Short phrases ("okay", "thank you") are common, so they must match much closer in time.
        var shortPhraseWindow: TimeInterval = 4
        var shortPhraseWordCount = 3
        /// Share of mic words that must appear, in order, in the meeting audio.
        /// Below 1 because the same speech transcribes differently through a speaker and a mic.
        var matchRatio = 0.6
    }

    private struct Entry {
        var words: [String]
        var date: Date
        var isPartial: Bool
    }

    private let configuration: Configuration
    private var entries: [Entry] = []

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    mutating func recordSystemText(_ text: String, isFinal: Bool, now: Date = .now) {
        // A partial stands in for the utterance in progress, so the next result replaces it.
        entries.removeAll { $0.isPartial || now.timeIntervalSince($0.date) > configuration.window }
        entries.append(Entry(words: Self.words(in: text), date: now, isPartial: !isFinal))
    }

    func isBleed(_ micText: String, now: Date = .now) -> Bool {
        let micWords = Self.words(in: micText)
        guard !micWords.isEmpty else { return false }

        let isShort = micWords.count < configuration.shortPhraseWordCount
        let window = isShort ? configuration.shortPhraseWindow : configuration.window
        let systemWords = entries
            .filter { now.timeIntervalSince($0.date) <= window }
            .flatMap(\.words)
        guard !systemWords.isEmpty else { return false }

        let matched = Self.longestCommonSubsequence(micWords, systemWords)
        if isShort { return matched == micWords.count }
        return Double(matched) / Double(micWords.count) >= configuration.matchRatio
    }

    mutating func reset() {
        entries.removeAll()
    }

    private static func words(in text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
    }

    private static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> Int {
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for wordA in a {
            for (index, wordB) in b.enumerated() {
                current[index + 1] = wordA == wordB
                    ? previous[index] + 1
                    : max(previous[index + 1], current[index])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
