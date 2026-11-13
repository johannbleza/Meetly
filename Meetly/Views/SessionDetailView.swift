import SwiftData
import SwiftUI

struct SessionDetailView: View {
    let session: MeetingSession
    var onContinue: (() -> Void)?
    var onArchive: (() -> Void)?
    var onUnarchive: (() -> Void)?
    var onExport: (() -> Void)?
    var onDelete: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @State private var qaController: MeetingQAController?
    @State private var actionItemsController: ActionItemsController?
    @State private var summaryController: MeetingSummaryController?
    @State private var questionText = ""
    @State private var searchText = ""
    /// `searchText` after a short debounce; everything below filters by this.
    @State private var appliedQuery = ""
    /// Transcript rows filtered and highlighted for `appliedQuery`, computed once per query.
    @State private var searchedTranscriptRows: [TranscriptRowModel] = []
    @State private var transcriptMatchCount = 0
    @State private var transcriptRows: [TranscriptRowModel] = []
    @State private var loadedTranscriptSessionID: UUID?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SessionDetailHeader(
                session: session,
                searchText: $searchText,
                isSearchFocused: $isSearchFocused,
                matchCount: isSearching ? matchCount : nil,
                onContinue: onContinue,
                onArchive: onArchive,
                onUnarchive: onUnarchive,
                onExport: onExport,
                onDelete: onDelete
            )
            AppDivider(axis: .horizontal)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if isSearching && matchCount == 0 {
                        searchEmptyState
                    } else {
                        if showsSummary {
                            SessionSummarySection(
                                session: session,
                                summaryController: summaryController,
                                highlightQuery: keywordQuery
                            )
                        }
                        SessionKeyPointsSection(
                            points: matchingKeyPoints,
                            highlightQuery: keywordQuery
                        )
                        if showsActionItems {
                            SessionActionItemsSection(
                                items: matchingActionItems,
                                controller: actionItemsController,
                                highlightQuery: keywordQuery,
                                isSearching: isSearching
                            )
                        }
                        SessionAskAISection(
                            qaController: qaController,
                            highlightQuery: keywordQuery,
                            matchingMessages: matchingAskAIMessages,
                            isSearching: isSearching
                        )

                        if showsTranscript {
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
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
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
        .background(alignment: .topLeading) {
            Button("Find in Meeting") {
                isSearchFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onAppear {
            configureControllers()
            loadTranscriptRows()
        }
        .onChange(of: session.endedAt) { _, _ in
            // A continued meeting gains segments under the same ID.
            loadTranscriptRows()
        }
        .onChange(of: session.id) { _, _ in
            configureControllers()
            questionText = ""
            searchText = ""
            appliedQuery = ""
            isSearchFocused = false
            loadTranscriptRows()
        }
        .task(id: searchText) {
            let query = KeywordHighlighter.normalizedQuery(searchText)
            // Apply immediately when clearing; otherwise wait for a pause in typing.
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            guard query != appliedQuery else { return }
            appliedQuery = query
            updateTranscriptSearch()
        }
    }

    private var keywordQuery: String {
        appliedQuery
    }

    private var isSearching: Bool {
        !keywordQuery.isEmpty
    }

    private var allTranscriptRows: [TranscriptRowModel] {
        if loadedTranscriptSessionID == session.id {
            return transcriptRows
        }
        return Self.makeTranscriptRows(from: session, highlightQuery: "")
    }

    private var displayedTranscriptRows: [TranscriptRowModel] {
        isSearching ? searchedTranscriptRows : allTranscriptRows
    }

    private func updateTranscriptSearch() {
        guard isSearching else {
            searchedTranscriptRows = []
            transcriptMatchCount = 0
            return
        }
        var count = 0
        var rows: [TranscriptRowModel] = []
        for row in allTranscriptRows {
            let occurrences = KeywordHighlighter.occurrenceCount(in: row.text, query: keywordQuery)
            guard occurrences > 0 else { continue }
            count += occurrences
            rows.append(row.highlighted(with: keywordQuery))
        }
        searchedTranscriptRows = rows.enumerated().map { index, row in
            row.withDivider(index != rows.count - 1)
        }
        transcriptMatchCount = count
    }

    private var matchingKeyPoints: [String] {
        let points = session.summary?.keyPoints ?? []
        guard isSearching else { return points }
        return points.filter { KeywordHighlighter.matches($0, query: keywordQuery) }
    }

    private var matchingActionItems: [ActionItem] {
        let items = session.summary?.sortedActionItems ?? []
        guard isSearching else { return items }
        return items.filter { KeywordHighlighter.matches($0.text, query: keywordQuery) }
    }

    private var matchingAskAIMessages: [ChatMessage] {
        let messages = qaController?.messages ?? []
        guard isSearching else { return messages }
        return messages.filter { KeywordHighlighter.matches($0.text, query: keywordQuery) }
    }

    private var showsSummary: Bool {
        guard isSearching else { return true }
        guard let summaryText = session.summary?.summaryText else { return false }
        return KeywordHighlighter.matches(summaryText, query: keywordQuery)
    }

    private var showsActionItems: Bool {
        !isSearching || !matchingActionItems.isEmpty
    }

    private var showsTranscript: Bool {
        !isSearching || !displayedTranscriptRows.isEmpty
    }

    private var matchCount: Int {
        guard isSearching else { return 0 }
        var count = 0
        if let summary = session.summary {
            count += KeywordHighlighter.occurrenceCount(in: summary.summaryText, query: keywordQuery)
            for point in summary.keyPoints {
                count += KeywordHighlighter.occurrenceCount(in: point, query: keywordQuery)
            }
            for item in summary.actionItems {
                count += KeywordHighlighter.occurrenceCount(in: item.text, query: keywordQuery)
            }
        }
        count += transcriptMatchCount
        for message in qaController?.messages ?? [] {
            count += KeywordHighlighter.occurrenceCount(in: message.text, query: keywordQuery)
        }
        return count
    }

    private var searchEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(AppTheme.textSecondary)
            Text("No matches for “\(keywordQuery)”")
                .font(.appBody)
                .foregroundStyle(AppTheme.textPrimary)
            Text("Try a different keyword in the summary, transcript, or action items.")
                .font(.appCaption)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .accessibilityElement(children: .combine)
    }

    private func configureControllers() {
        qaController = MeetingQAController(session: session)
        actionItemsController = ActionItemsController(session: session, modelContext: modelContext)
        summaryController = MeetingSummaryController(session: session, modelContext: modelContext)
    }

    private func loadTranscriptRows() {
        transcriptRows = Self.makeTranscriptRows(from: session, highlightQuery: "")
        loadedTranscriptSessionID = session.id
        updateTranscriptSearch()
    }

    private static func makeTranscriptRows(from session: MeetingSession, highlightQuery: String) -> [TranscriptRowModel] {
        let segments = session.segments.sorted { $0.timestamp < $1.timestamp }
        let lastID = segments.last?.persistentModelID
        return segments.map { segment in
            TranscriptRowModel(
                id: segment.persistentModelID,
                timestampText: segment.timestamp.formatted(date: .omitted, time: .standard),
                speaker: segment.speaker,
                text: segment.text,
                showDivider: segment.persistentModelID != lastID,
                highlightQuery: highlightQuery
            )
        }
    }
}

private struct SessionDetailHeader: View {
    let session: MeetingSession
    @Binding var searchText: String
    var isSearchFocused: FocusState<Bool>.Binding
    var matchCount: Int?
    var onContinue: (() -> Void)?
    var onArchive: (() -> Void)?
    var onUnarchive: (() -> Void)?
    var onExport: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.displayTitle)
                    .font(.appTitle)
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(2)

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
            .textSelection(.enabled)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            AppSearchField(
                text: $searchText,
                placeholder: "Search in meeting",
                accessory: matchCount.map(String.init),
                isFocused: isSearchFocused
            )
            .frame(width: 240)
            .layoutPriority(1)
            .help("Search in meeting (⌘F)")
            .accessibilityLabel("Search in meeting")
            .accessibilityHint("Finds keywords in the summary, key points, action items, and transcript. Press Command F to focus.")

            if let onContinue {
                Button(action: onContinue) {
                    Label("Continue Meeting", systemImage: "mic.fill")
                        .font(.appBody.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(AppTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .fixedSize()
                .help("Keep recording into this meeting. The summary is regenerated when you stop.")
            }

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
                .accessibilityLabel("Meeting actions")
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
    var highlightQuery: String = ""

    var body: some View {
        DetailSectionBlock(title: "Summary") {
            if let summary = session.summary {
                VStack(alignment: .leading, spacing: 10) {
                    HighlightedText(text: summary.summaryText, query: highlightQuery)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if highlightQuery.isEmpty {
                        regenerateSummaryControls(hasSummary: true)
                    }
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
    let points: [String]
    var highlightQuery: String = ""

    var body: some View {
        if !points.isEmpty {
            DetailSectionBlock(title: "Key Points") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(points, id: \.self) { point in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                                .foregroundStyle(AppTheme.accent)
                            HighlightedText(text: point, query: highlightQuery)
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
    let items: [ActionItem]
    let controller: ActionItemsController?
    var highlightQuery: String = ""
    var isSearching: Bool = false

    var body: some View {
        DetailSectionBlock(title: "Action Items") {
            VStack(alignment: .leading, spacing: 10) {
                if items.isEmpty {
                    Text("No action items yet. Generate them from the meeting summary and transcript.")
                        .font(.appCaption)
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items, id: \.persistentModelID) { item in
                            ActionItemRow(item: item, highlightQuery: highlightQuery) {
                                controller?.toggleCompletion(for: item)
                            }
                        }
                    }
                }

                if !isSearching, let controller {
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
    var highlightQuery: String = ""
    var matchingMessages: [ChatMessage] = []
    var isSearching: Bool = false

    var body: some View {
        if !isSearching || !matchingMessages.isEmpty {
            DetailSectionBlock(title: "Ask AI") {
                VStack(alignment: .leading, spacing: 12) {
                    if let qaController {
                        if !isSearching {
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
                        }

                        if !matchingMessages.isEmpty || (!isSearching && qaController.isAwaitingAnswer) {
                            ChatMessageListView(
                                messages: matchingMessages,
                                isAwaitingAnswer: isSearching ? false : qaController.isAwaitingAnswer,
                                style: .home,
                                scrollable: false,
                                highlightQuery: highlightQuery
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, 24)
        }
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
    let highlightQuery: String

    func highlighted(with query: String) -> TranscriptRowModel {
        TranscriptRowModel(
            id: id,
            timestampText: timestampText,
            speaker: speaker,
            text: text,
            showDivider: showDivider,
            highlightQuery: query
        )
    }

    func withDivider(_ showDivider: Bool) -> TranscriptRowModel {
        TranscriptRowModel(
            id: id,
            timestampText: timestampText,
            speaker: speaker,
            text: text,
            showDivider: showDivider,
            highlightQuery: highlightQuery
        )
    }
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
                    HighlightedText(text: row.text, query: row.highlightQuery)
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
    var highlightQuery: String = ""
    let onToggle: () -> Void

    var body: some View {
        // Only the checkbox toggles, so the text stays selectable.
        HStack(alignment: .top, spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(item.isCompleted ? AppTheme.success : AppTheme.textSecondary)
                    .frame(width: 20, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.isCompleted ? "Mark as not done" : "Mark as done")
            .accessibilityLabel(item.isCompleted ? "Mark as not done" : "Mark as done")

            HighlightedText(
                text: item.text,
                query: highlightQuery,
                foreground: item.isCompleted ? AppTheme.textSecondary : AppTheme.textPrimary
            )
            .strikethrough(item.isCompleted, color: AppTheme.textSecondary)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
