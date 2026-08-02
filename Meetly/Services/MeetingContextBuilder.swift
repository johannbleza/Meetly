import Foundation

enum MeetingContextBuilder {
    static func context(for session: MeetingSession) -> String {
        var parts: [String] = []

        if let summary = session.summary {
            var summaryBlock = "Meeting summary:\n\(summary.summaryText)"
            if !summary.keyPoints.isEmpty {
                summaryBlock += "\n\nKey points:\n" + summary.keyPoints.map { "- \($0)" }.joined(separator: "\n")
            }
            if !summary.sortedActionItems.isEmpty {
                summaryBlock += "\n\nAction items:\n" + summary.sortedActionItems.map { item in
                    let marker = item.isCompleted ? "[done]" : "[pending]"
                    return "- \(marker) \(item.text)"
                }.joined(separator: "\n")
            }
            parts.append(summaryBlock)
        }

        let transcript = transcriptText(for: session)
        if !transcript.isEmpty {
            parts.append("Meeting transcript:\n\(transcript)")
        }

        return parts.joined(separator: "\n\n")
    }

    static func transcriptText(for session: MeetingSession) -> String {
        session.segments
            .sorted { $0.timestamp < $1.timestamp }
            .map { "[\($0.speaker.label)] \($0.text)" }
            .joined(separator: "\n")
    }

    static func hasContent(for session: MeetingSession) -> Bool {
        !context(for: session).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
