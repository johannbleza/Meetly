import SwiftUI

enum KeywordHighlighter {
    static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(_ text: String, query: String) -> Bool {
        let needle = normalizedQuery(query)
        guard !needle.isEmpty else { return true }
        return text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    static func occurrenceCount(in text: String, query: String) -> Int {
        let needle = normalizedQuery(query)
        guard !needle.isEmpty else { return 0 }

        var count = 0
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<text.endIndex
              ) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }

    static func highlighted(
        _ text: String,
        query: String,
        foreground: Color = AppTheme.textPrimary
    ) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.foregroundColor = foreground

        let needle = normalizedQuery(query)
        guard !needle.isEmpty else { return attributed }

        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<text.endIndex
              ) {
            if let attributedRange = Range(range, in: attributed) {
                attributed[attributedRange].backgroundColor = AppTheme.warning.opacity(0.88)
                attributed[attributedRange].foregroundColor = Color.black
                attributed[attributedRange].inlinePresentationIntent = .stronglyEmphasized
            }
            searchStart = range.upperBound
        }
        return attributed
    }
}

struct HighlightedText: View {
    let text: String
    let query: String
    var font: Font = .appBody
    var foreground: Color = AppTheme.textPrimary

    var body: some View {
        Text(KeywordHighlighter.highlighted(text, query: query, foreground: foreground))
            .font(font)
    }
}
