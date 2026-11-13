import AppKit
import Foundation
import UniformTypeIdentifiers

enum MeetingMarkdownExporter {
    static func markdown(for session: MeetingSession) -> String {
        var lines: [String] = []

        lines.append("# \(session.displayTitle)")
        lines.append("")

        var metadata: [String] = [
            session.startedAt.formatted(date: .complete, time: .shortened),
        ]
        if let duration = session.formattedDuration() {
            metadata.append(duration)
        }
        lines.append(metadata.joined(separator: " · "))
        lines.append("")

        let summary = summaryMarkdown(for: session)
        if !summary.isEmpty {
            lines.append(summary)
            lines.append("")
        }

        lines.append("## Transcript")
        lines.append("")

        let sortedSegments = session.segments.sorted { $0.timestamp < $1.timestamp }
        if sortedSegments.isEmpty {
            lines.append("_No transcript captured._")
        } else {
            for segment in sortedSegments {
                let time = segment.timestamp.formatted(date: .omitted, time: .standard)
                lines.append("**\(segment.speaker.label)** _(\(time))_")
                lines.append("")
                lines.append(segment.text)
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// The summary, key points and action items as Markdown, or an empty string with no summary.
    static func summaryMarkdown(for session: MeetingSession) -> String {
        guard let summary = session.summary else { return "" }
        var lines: [String] = ["## Summary", "", summary.summaryText]

        if !summary.sortedActionItems.isEmpty {
            lines += ["", "## Action Items", ""]
            for item in summary.sortedActionItems {
                let checkbox = item.isCompleted ? "[x]" : "[ ]"
                lines.append("- \(checkbox) \(item.text)")
            }
        }

        if !summary.keyPoints.isEmpty {
            lines += ["", "## Key Points", ""]
            lines += summary.keyPoints.map { "- \($0)" }
        }

        return lines.joined(separator: "\n")
    }

    /// The transcript as plain text, one "Speaker (m:ss): text" line per segment.
    static func transcriptText(for session: MeetingSession) -> String {
        session.segments
            .sorted { $0.timestamp < $1.timestamp }
            .map { segment in
                let elapsed = elapsedTimestamp(segment.timestamp, since: session.startedAt)
                return "\(segment.speaker.label) (\(elapsed)): \(segment.text)"
            }
            .joined(separator: "\n\n")
    }

    /// Time since the meeting started, as "m:ss" or "h:mm:ss".
    static func elapsedTimestamp(_ date: Date, since start: Date) -> String {
        clockDuration(date.timeIntervalSince(start))
    }

    /// A duration as "m:ss" or "h:mm:ss".
    static func clockDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func export(_ session: MeetingSession) {
        let panel = NSSavePanel()
        panel.title = "Export Meeting as Markdown"
        panel.nameFieldStringValue = suggestedFilename(for: session)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let content = markdown(for: session)
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showExportError(error.localizedDescription)
        }
    }

    private static func showExportError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Export Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private static func suggestedFilename(for session: MeetingSession) -> String {
        let base = session.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if let base, !base.isEmpty {
            name = base
        } else {
            name = session.startedAt.formatted(.dateTime.year().month().day().hour().minute())
        }
        let sanitized = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(sanitized).md"
    }
}
