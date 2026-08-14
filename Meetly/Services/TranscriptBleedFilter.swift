import Foundation

/// Drops microphone transcripts that repeat recent meeting-audio speech.
///
/// Catches bleed that leaks through the audio gate (channel lag, ASR wording
/// differences) without a model round-trip on the live caption path.
struct TranscriptBleedFilter {
    private struct Entry {
        var text: String
        var date: Date
        var isPartial: Bool
    }

    private var others: [Entry] = []
    private let window: TimeInterval = 8

    mutating func reset() {
        others.removeAll()
    }

    mutating func recordOtherFinal(_ text: String) {
        prune()
        others.removeAll { $0.isPartial }
        others.append(Entry(text: text, date: .now, isPartial: false))
    }

    mutating func recordOtherPartial(_ text: String) {
        prune()
        if let index = others.lastIndex(where: { $0.isPartial }) {
            others[index].text = text
            others[index].date = .now
        } else {
            others.append(Entry(text: text, date: .now, isPartial: true))
        }
    }

    mutating func looksLikeBleed(_ text: String) -> Bool {
        prune()
        return Self.matches(text, against: others.map(\.text))
    }

    static func textsMatch(_ lhs: String, _ rhs: String) -> Bool {
        matches(lhs, against: [rhs])
    }

    private mutating func prune() {
        let cutoff = Date().addingTimeInterval(-window)
        others.removeAll { $0.date < cutoff }
    }

    private static func matches(_ text: String, against others: [String]) -> Bool {
        let candidate = NormalizedText(text)
        guard candidate.isComparable else { return false }

        for other in others {
            if candidate.matches(NormalizedText(other)) {
                return true
            }
        }

        let combined = NormalizedText(others.joined(separator: " "))
        return candidate.matches(combined)
    }
}

private struct NormalizedText {
    let tokens: [String]
    let tokenSet: Set<String>

    var isComparable: Bool {
        tokens.count >= 4 || (tokens.count >= 3 && tokens.joined(separator: " ").count >= 20)
    }

    init(_ text: String) {
        let folded = text.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" {
                return Character(scalar)
            }
            return " "
        }
        tokens = String(folded)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 1 }
        tokenSet = Set(tokens)
    }

    func matches(_ other: NormalizedText) -> Bool {
        guard !tokens.isEmpty, !other.tokens.isEmpty else { return false }

        let (shorter, longer) = tokens.count <= other.tokens.count
            ? (tokens, other.tokens)
            : (other.tokens, tokens)
        if shorter.count >= 4, longer.containsWindow(shorter) {
            return true
        }

        let intersection = tokenSet.intersection(other.tokenSet).count
        let union = tokenSet.union(other.tokenSet).count
        guard union > 0 else { return false }

        let jaccard = Float(intersection) / Float(union)
        let lengthRatio = Float(min(tokens.count, other.tokens.count))
            / Float(max(tokens.count, other.tokens.count))
        return lengthRatio >= 0.5 && jaccard >= 0.68
    }
}

private extension Array where Element: Equatable {
    func containsWindow(_ sub: [Element]) -> Bool {
        guard sub.count <= count else { return false }
        for start in 0...(count - sub.count) {
            if self[start..<(start + sub.count)].elementsEqual(sub) {
                return true
            }
        }
        return false
    }
}
