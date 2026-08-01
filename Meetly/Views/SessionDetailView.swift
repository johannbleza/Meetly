import SwiftData
import SwiftUI

struct SessionDetailView: View {
    let session: MeetingSession
    var onArchive: (() -> Void)?
    var onUnarchive: (() -> Void)?
    var onExport: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            detailHeader
            AppDivider(axis: .horizontal)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let summary = session.summary {
                        summarySection(summary)
                    }
                    transcriptSection
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .appPanelBackground(AppTheme.bgPrimary)
    }

    private var detailHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.displayTitle)
                    .font(.appTitle)
                    .foregroundStyle(AppTheme.textPrimary)

                HStack(spacing: 12) {
                    Text(session.startedAt.formatted(date: .complete, time: .shortened))
                    if let duration = session.formattedDuration() {
                        Text("·")
                        Text(duration)
                    }
                }
                .font(.appCaption)
                .foregroundStyle(AppTheme.textSecondary)
            }

            Spacer()

            if onExport != nil || onArchive != nil || onUnarchive != nil || onDelete != nil {
                Menu {
                    if let onExport {
                        Button("Export as Markdown") {
                            onExport()
                        }
                    }
                    if let onUnarchive {
                        Button("Unarchive") {
                            onUnarchive()
                        }
                    }
                    if let onArchive {
                        Button("Archive") {
                            onArchive()
                        }
                    }
                    if let onDelete {
                        Divider()
                        Button("Delete", role: .destructive) {
                            onDelete()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(AppTheme.bgSidebar)
    }

    @ViewBuilder
    private func summarySection(_ summary: MeetingSummary) -> some View {
        sectionBlock(title: "Summary") {
            Text(summary.summaryText)
                .font(.appBody)
                .foregroundStyle(AppTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if !summary.keyPoints.isEmpty {
            sectionBlock(title: "Key Points") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(summary.keyPoints, id: \.self) { point in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                                .foregroundStyle(AppTheme.accent)
                            Text(point)
                                .font(.appBody)
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        if !summary.actionItems.isEmpty {
            sectionBlock(title: "Action Items") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(summary.actionItems, id: \.self) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                                .foregroundStyle(AppTheme.accent)
                            Text(item)
                                .font(.appBody)
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var transcriptSection: some View {
        sectionBlock(title: "Transcript") {
            if session.segments.isEmpty {
                Text("No transcript captured.")
                    .font(.appBody)
                    .foregroundStyle(AppTheme.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sortedSegments, id: \.persistentModelID) { segment in
                        transcriptRow(segment)
                        if segment.persistentModelID != sortedSegments.last?.persistentModelID {
                            AppDivider(axis: .horizontal)
                                .padding(.vertical, 8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func transcriptRow(_ segment: TranscriptSegment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(segment.timestamp.formatted(date: .omitted, time: .standard))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 96, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 4) {
                Text(segment.speaker.label)
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(segment.speaker == .me ? AppTheme.accent : AppTheme.textSecondary)
                Text(segment.text)
                    .font(.appBody)
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    private func sectionBlock<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            AppSectionHeader(title: title)
            content()
        }
    }

    private var sortedSegments: [TranscriptSegment] {
        session.segments.sorted { $0.timestamp < $1.timestamp }
    }
}

#Preview {
    let session = MeetingSession(title: "Weekly Sync")
    session.segments = [
        TranscriptSegment(text: "Let's review the roadmap.", speaker: .other),
        TranscriptSegment(text: "Sounds good.", speaker: .me),
    ]
    session.summary = MeetingSummary(
        summaryText: "The team reviewed the roadmap and agreed on next steps.",
        keyPoints: ["Roadmap review"],
        actionItems: ["Share updated timeline"]
    )
    return SessionDetailView(
        session: session,
        onArchive: {},
        onDelete: {}
    )
    .frame(width: 700, height: 600)
    .preferredColorScheme(.dark)
}
