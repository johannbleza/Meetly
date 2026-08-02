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

        if let summary = session.summary {
            lines.append("## Summary")
            lines.append("")
            lines.append(summary.summaryText)
            lines.append("")

            if !summary.keyPoints.isEmpty {
                lines.append("## Key Points")
                lines.append("")
                for point in summary.keyPoints {
                    lines.append("- \(point)")
                }
                lines.append("")
            }

            if !summary.sortedActionItems.isEmpty {
                lines.append("## Action Items")
                lines.append("")
                for item in summary.sortedActionItems {
                    let checkbox = item.isCompleted ? "[x]" : "[ ]"
                    lines.append("- \(checkbox) \(item.text)")
                }
                lines.append("")
            }
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
