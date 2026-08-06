import SwiftData
import SwiftUI

struct SessionDetailView: View {
    let session: MeetingSession
    var onArchive: (() -> Void)?
    var onUnarchive: (() -> Void)?
    var onExport: (() -> Void)?
    var onDelete: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @State private var qaController: MeetingQAController?
    @State private var actionItemsController: ActionItemsController?
    @State private var summaryController: MeetingSummaryController?
    @State private var questionText = ""

    var body: some View {
        VStack(spacing: 0) {
            detailHeader
            AppDivider(axis: .horizontal)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    summaryContent
                    askAISection
                    transcriptSection
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppDivider(axis: .horizontal)

            MeetingQAInputBar(
                text: $questionText,
                isDisabled: qaController.map { !$0.canAsk } ?? true
            ) { question in
                Task { await qaController?.ask(question) }
            }
        }
        .appPanelBackground(AppTheme.bgPrimary)
        .onAppear {
            configureControllers()
        }
        .onChange(of: session.id) { _, _ in
            configureControllers()
            questionText = ""
        }
    }

    private func configureControllers() {
        qaController = MeetingQAController(session: session)
        actionItemsController = ActionItemsController(session: session, modelContext: modelContext)
        summaryController = MeetingSummaryController(session: session, modelContext: modelContext)
    }

    private var askAISection: some View {
        sectionBlock(title: "Ask AI") {
            VStack(alignment: .leading, spacing: 12) {
                if let qaController {
                    if !qaController.isAvailable {
                        Text(qaController.availabilityMessage ?? "Configure AI in Settings to ask questions about this meeting.")
                            .font(.appCaption)
                            .foregroundStyle(AppTheme.textSecondary)
                    } else if !qaController.hasContent {
                        Text("This meeting has no transcript or summary to ask about yet.")
                            .font(.appCaption)
                            .foregroundStyle(AppTheme.textSecondary)
                    } else if qaController.messages.isEmpty {
                        Text("Ask a question about this meeting's transcript or summary.")
                            .font(.appCaption)
                            .foregroundStyle(AppTheme.textSecondary)
                    }

                    if !qaController.messages.isEmpty || qaController.isAwaitingAnswer {
                        ChatMessageListView(
                            messages: qaController.messages,
                            isAwaitingAnswer: qaController.isAwaitingAnswer,
                            style: .home,
                            scrollable: false
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
    private var summaryContent: some View {
        if let summary = session.summary {
            summarySection(summary)
        } else {
            sectionBlock(title: "Summary") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No summary yet. Generate one from the meeting transcript.")
                        .font(.appCaption)
                        .foregroundStyle(AppTheme.textSecondary)
                    regenerateSummaryControls(hasSummary: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func summarySection(_ summary: MeetingSummary) -> some View {
        sectionBlock(title: "Summary") {
            VStack(alignment: .leading, spacing: 10) {
                Text(summary.summaryText)
                    .font(.appBody)
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                regenerateSummaryControls(hasSummary: true)
            }
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

        actionItemsSection(summary)
    }

    @ViewBuilder
    private func regenerateSummaryControls(hasSummary: Bool) -> some View {
        if let summaryController {
            if let errorMessage = summaryController.errorMessage {
                Text(errorMessage)
                    .font(.appCaption)
                    .foregroundStyle(AppTheme.danger)
            }

            Button {
                Task { await summaryController.generate() }
            } label: {
                HStack(spacing: 6) {
                    if summaryController.isGenerating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(hasSummary ? "Regenerate Summary" : "Generate Summary")
                }
                .font(.appCaption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.accent)
            .disabled(!summaryController.canGenerate)
            .opacity(summaryController.canGenerate ? 1 : 0.5)
        }
    }

    @ViewBuilder
    private func actionItemsSection(_ summary: MeetingSummary) -> some View {
        sectionBlock(title: "Action Items") {
            VStack(alignment: .leading, spacing: 10) {
                let items = summary.sortedActionItems

                if items.isEmpty {
                    Text("No action items yet. Generate them from the meeting summary and transcript.")
                        .font(.appCaption)
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items, id: \.persistentModelID) { item in
                            ActionItemRow(item: item) {
                                actionItemsController?.toggleCompletion(for: item)
                            }
                        }
                    }
                }

                if let actionItemsController {
                    if let errorMessage = actionItemsController.errorMessage {
                        Text(errorMessage)
                            .font(.appCaption)
                            .foregroundStyle(AppTheme.danger)
                    }

                    Button {
                        Task { await actionItemsController.generate() }
                    } label: {
                        HStack(spacing: 6) {
                            if actionItemsController.isGenerating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "sparkles")
                            }
                            Text(items.isEmpty ? "Generate Action Items" : "Regenerate Action Items")
                        }
                        .font(.appCaption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.accent)
                    .disabled(!actionItemsController.canGenerate)
                    .opacity(actionItemsController.canGenerate ? 1 : 0.5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

private struct ActionItemRow: View {
    let item: ActionItem
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(item.isCompleted ? AppTheme.success : AppTheme.textSecondary)
                    .frame(width: 20, alignment: .center)

                Text(item.text)
                    .font(.appBody)
                    .foregroundStyle(item.isCompleted ? AppTheme.textSecondary : AppTheme.textPrimary)
                    .strikethrough(item.isCompleted, color: AppTheme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        actionItems: [
            ActionItem(text: "Share updated timeline", sortOrder: 0),
            ActionItem(text: "Schedule design review", sortOrder: 1),
        ]
    )
    return SessionDetailView(
        session: session,
        onArchive: {},
        onDelete: {}
    )
    .frame(width: 700, height: 600)
    .preferredColorScheme(.dark)
}
