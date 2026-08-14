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
    @State private var transcriptRows: [TranscriptRowModel] = []
    @State private var loadedTranscriptSessionID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            SessionDetailHeader(
                session: session,
                onArchive: onArchive,
                onUnarchive: onUnarchive,
                onExport: onExport,
                onDelete: onDelete
            )
            AppDivider(axis: .horizontal)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    SessionSummarySection(session: session, summaryController: summaryController)
                    SessionKeyPointsSection(session: session)
                    SessionActionItemsSection(session: session, controller: actionItemsController)
                    SessionAskAISection(qaController: qaController)

                    AppSectionHeader(title: "Transcript")
                        .padding(.bottom, 10)

                    let rows = displayedTranscriptRows
                    if rows.isEmpty {
                        Text("No transcript captured.")
                            .font(.appBody)
                            .foregroundStyle(AppTheme.textSecondary)
                    } else {
                        ForEach(rows) { row in
                            TranscriptRowView(row: row)
                                .equatable()
                        }
                    }
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
            loadTranscriptRows()
        }
        .onChange(of: session.id) { _, _ in
            configureControllers()
            questionText = ""
            loadTranscriptRows()
        }
    }

    private var displayedTranscriptRows: [TranscriptRowModel] {
        if loadedTranscriptSessionID == session.id {
            return transcriptRows
        }
        return Self.makeTranscriptRows(from: session)
    }

    private func configureControllers() {
        qaController = MeetingQAController(session: session)
        actionItemsController = ActionItemsController(session: session, modelContext: modelContext)
        summaryController = MeetingSummaryController(session: session, modelContext: modelContext)
    }

    private func loadTranscriptRows() {
        transcriptRows = Self.makeTranscriptRows(from: session)
        loadedTranscriptSessionID = session.id
    }

    private static func makeTranscriptRows(from session: MeetingSession) -> [TranscriptRowModel] {
        let segments = session.segments.sorted { $0.timestamp < $1.timestamp }
        let lastID = segments.last?.persistentModelID
        return segments.map { segment in
            TranscriptRowModel(
                id: segment.persistentModelID,
                timestampText: segment.timestamp.formatted(date: .omitted, time: .standard),
                speaker: segment.speaker,
                text: segment.text,
                showDivider: segment.persistentModelID != lastID
            )
        }
    }
}

private struct SessionDetailHeader: View {
    let session: MeetingSession
    var onArchive: (() -> Void)?
    var onUnarchive: (() -> Void)?
    var onExport: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
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
}

private struct SessionSummarySection: View {
    let session: MeetingSession
    let summaryController: MeetingSummaryController?

    var body: some View {
        DetailSectionBlock(title: "Summary") {
            if let summary = session.summary {
                VStack(alignment: .leading, spacing: 10) {
                    Text(summary.summaryText)
                        .font(.appBody)
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    regenerateSummaryControls(hasSummary: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No summary yet. Generate one from the meeting transcript.")
                        .font(.appCaption)
                        .foregroundStyle(AppTheme.textSecondary)
                    regenerateSummaryControls(hasSummary: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.bottom, 24)
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
}

private struct SessionKeyPointsSection: View {
    let session: MeetingSession

    var body: some View {
        if let keyPoints = session.summary?.keyPoints, !keyPoints.isEmpty {
            DetailSectionBlock(title: "Key Points") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(keyPoints, id: \.self) { point in
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
            .padding(.bottom, 24)
        }
    }
}

private struct SessionActionItemsSection: View {
    let session: MeetingSession
    let controller: ActionItemsController?

    var body: some View {
        let items = session.summary?.sortedActionItems ?? []

        DetailSectionBlock(title: "Action Items") {
            VStack(alignment: .leading, spacing: 10) {
                if items.isEmpty {
                    Text("No action items yet. Generate them from the meeting summary and transcript.")
                        .font(.appCaption)
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items, id: \.persistentModelID) { item in
                            ActionItemRow(item: item) {
                                controller?.toggleCompletion(for: item)
                            }
                        }
                    }
                }

                if let controller {
                    if let errorMessage = controller.errorMessage {
                        Text(errorMessage)
                            .font(.appCaption)
                            .foregroundStyle(AppTheme.danger)
                    }

                    Button {
                        Task { await controller.generate() }
                    } label: {
                        HStack(spacing: 6) {
                            if controller.isGenerating {
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
                    .disabled(!controller.canGenerate)
                    .opacity(controller.canGenerate ? 1 : 0.5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 24)
    }
}

private struct SessionAskAISection: View {
    let qaController: MeetingQAController?

    var body: some View {
        DetailSectionBlock(title: "Ask AI") {
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
        .padding(.bottom, 24)
    }
}

private struct DetailSectionBlock<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppSectionHeader(title: title)
            content
        }
    }
}

private struct TranscriptRowModel: Identifiable, Equatable {
    let id: PersistentIdentifier
    let timestampText: String
    let speaker: Speaker
    let text: String
    let showDivider: Bool
}

private struct TranscriptRowView: View, Equatable {
    let row: TranscriptRowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Text(row.timestampText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 96, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: 4) {
                    Text(row.speaker.label)
                        .font(.appCaption.weight(.semibold))
                        .foregroundStyle(row.speaker == .me ? AppTheme.accent : AppTheme.textSecondary)
                    Text(row.text)
                        .font(.appBody)
                        .foregroundStyle(AppTheme.textPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)

            if row.showDivider {
                AppDivider(axis: .horizontal)
                    .padding(.vertical, 8)
            }
        }
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
