import SwiftData
import SwiftUI

/// A saved meeting: a single centered column with the date and title, Summary / Transcript / Ask AI
/// tabs, and a floating "Resume" + "Ask about this meeting…" bar at the bottom.
struct SessionDetailView: View {
    let session: MeetingSession
    var onContinue: (() -> Void)?
    var onArchive: (() -> Void)?
    var onUnarchive: (() -> Void)?
    var onExport: (() -> Void)?
    var onDelete: (() -> Void)?
    /// While the home page's featured card rises into this header (see `MeetingHeroMotion`):
    /// the card stands in for the date and title, and the tabs open up between the title and
    /// the summary.
    var hero: MeetingHeroMotion?
    /// Where this page reports the header and tab bar positions the card's motion aims for.
    var heroAnchor: MeetingHeroAnchor?

    @Environment(\.modelContext) private var modelContext
    @State private var qaController: MeetingQAController?
    @State private var actionItemsController: ActionItemsController?
    @State private var summaryController: MeetingSummaryController?
    @State private var selectedTab: DetailTab = .summary
    @State private var questionText = ""
    @State private var searchText = ""
    /// `searchText` after a short debounce; everything below filters by this.
    @State private var appliedQuery = ""
    /// Transcript rows filtered and highlighted for `appliedQuery`, computed once per query.
    @State private var searchedTranscriptRows: [TranscriptRowModel] = []
    @State private var transcriptMatchCount = 0
    @State private var transcriptRows: [TranscriptRowModel] = []
    @State private var loadedTranscriptSessionID: UUID?
    @State private var didCopyTranscript = false
    @FocusState private var isSearchFocused: Bool

    private static let columnWidth = AppTheme.pageMaxWidth
    private static let bottomAnchorID = "detail-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.frame(in: .named(MeetingHeroAnchor.coordinateSpace)).minY
                        } action: { heroAnchor?.pageHeaderTop = $0 }
                    tabBar
                        .padding(.top, 22)
                        .padding(.bottom, 24)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { heroAnchor?.tabBlockHeight = $0 }
                        // Opens from the bottom: the gap under the title grows into the tabs.
                        .mask(alignment: .bottom) {
                            Rectangle().frame(height: hero.map { $0.tabBlockHeight - $0.summaryShift * (1 - $0.progress) })
                        }
                        .offset(y: heroBodyOffset)
                    tabContent
                        .offset(y: heroBodyOffset)
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                }
                .textSelection(.enabled)
                .frame(maxWidth: Self.columnWidth, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 28)
                // Room to scroll the last lines out from under the floating ask bar.
                .padding(.bottom, 110)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: qaController?.messages.last?.id) { _, _ in
                scrollAskAIToBottom(proxy)
            }
            .onChange(of: qaController?.isAwaitingAnswer) { _, _ in
                scrollAskAIToBottom(proxy)
            }
        }
        .overlay(alignment: .bottom) { askBar }
        .appPanelBackground(AppTheme.bgPrimary)
        .background(alignment: .topLeading) { keyboardShortcuts }
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
            didCopyTranscript = false
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

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                metadataLine
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(hero == nil ? 1 : 0)
                headerActions
                    .opacity(Double(hero?.progress ?? 1))
            }
            Text(session.displayTitle)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(hero == nil ? 1 : 0)
        }
    }

    /// Everything under the header starts with its summary exactly under the featured card's
    /// summary, and moves with it into place.
    private var heroBodyOffset: CGFloat {
        guard let hero else { return 0 }
        return (-hero.lift - hero.summaryShift) * (1 - hero.progress)
    }

    private var metadataLine: some View {
        HStack(spacing: 6) {
            Text(session.startedAt.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
            Text("•")
            Text(session.startedAt.formatted(date: .omitted, time: .shortened))
            if let duration = shortDuration {
                Text("•")
                Text(duration)
            }
            if session.isArchivedValue {
                Text("Archived")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(AppTheme.bgInput))
                    .padding(.leading, 4)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(AppTheme.textSecondary)
        .lineLimit(1)
    }

    private var shortDuration: String? {
        guard let duration = session.duration else { return nil }
        let minutes = Int(duration.rounded()) / 60
        if minutes == 0 { return "\(Int(duration.rounded()))s" }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private var headerActions: some View {
        MeetingShareButton(
            session: session,
            onExport: onExport,
            onArchive: onArchive,
            onUnarchive: onUnarchive,
            onDelete: onDelete
        )
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 12) {
            AppSegmentedControl(
                selection: $selectedTab,
                segments: DetailTab.allCases.map { tab in
                    .init(value: tab, title: tab.title, badge: tabBadge(tab))
                },
                height: 32
            )
            Spacer(minLength: 0)
            AppSearchField(
                text: $searchText,
                placeholder: "Search in meeting",
                accessory: isSearching ? String(matchCount) : nil,
                isFocused: $isSearchFocused
            )
            .frame(maxWidth: 220)
            .help("Search in meeting (⌘F)")
            .accessibilityLabel("Search in meeting")
            .accessibilityHint("Finds keywords in the summary, transcript, and Ask AI history. Press Command F to focus.")
        }
    }

    /// While searching, each tab shows how many matches it has.
    private func tabBadge(_ tab: DetailTab) -> Int? {
        guard isSearching else { return nil }
        return matchCount(in: tab)
    }

    @ViewBuilder
    private var tabContent: some View {
        if isSearching && matchCount(in: selectedTab) == 0 {
            searchEmptyState
        } else {
            switch selectedTab {
            case .summary:
                summaryTab
            case .transcript:
                transcriptTab
            case .askAI:
                MeetingAskAITab(
                    qaController: qaController,
                    highlightQuery: keywordQuery,
                    onAsk: ask
                )
            }
        }
    }

    // MARK: Summary tab

    @ViewBuilder
    private var summaryTab: some View {
        if let summary = session.summary {
            if !isSearching || KeywordHighlighter.matches(summary.summaryText, query: keywordQuery) {
                HighlightedText(text: summary.summaryText, query: keywordQuery, font: .system(size: 15))
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !isSearching {
            EmptySummaryCard(controller: summaryController)
        }

        if !isSearching || !matchingActionItems.isEmpty {
            SessionActionItemsSection(
                items: matchingActionItems,
                controller: actionItemsController,
                highlightQuery: keywordQuery,
                isSearching: isSearching
            )
        }

        if !matchingKeyPoints.isEmpty {
            SummarySectionHeading(title: "Key Points")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(matchingKeyPoints, id: \.self) { point in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(AppTheme.textSecondary)
                            .frame(width: 5, height: 5)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                        HighlightedText(text: point, query: keywordQuery, font: .system(size: 15))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        if !isSearching, let summary = session.summary {
            SummaryFooter(generatedAt: summary.generatedAt, controller: summaryController)
                .padding(.top, 32)
        }
    }

    // MARK: Transcript tab

    @ViewBuilder
    private var transcriptTab: some View {
        let rows = displayedTranscriptRows
        if rows.isEmpty {
            Text("No transcript captured.")
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.textSecondary)
        } else {
            HStack {
                Spacer()
                DetailPillButton(
                    title: didCopyTranscript ? "Copied" : "Copy full transcript",
                    systemImage: didCopyTranscript ? "checkmark" : "doc.on.doc",
                    isSubtle: true,
                    action: copyTranscript
                )
            }
            .padding(.bottom, 4)

            ForEach(rows) { row in
                TranscriptRowView(row: row)
                    .equatable()
            }
        }
    }

    private func copyTranscript() {
        MeetingMarkdownExporter.copyToPasteboard(MeetingMarkdownExporter.transcriptText(for: session))
        didCopyTranscript = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopyTranscript = false
        }
    }

    // MARK: Ask bar

    private var askBar: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [AppTheme.bgPrimary.opacity(0), AppTheme.bgPrimary],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 36)
            .allowsHitTesting(false)

            MeetingAskBar(
                text: $questionText,
                isDisabled: !(qaController?.canAsk ?? false),
                onResume: onContinue,
                onSend: ask
            )
            .frame(maxWidth: Self.columnWidth)
            .padding(.horizontal, 32)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity)
            .background(AppTheme.bgPrimary)
        }
    }

    private func ask(_ question: String) {
        guard let qaController else { return }
        withAnimation(.snappy(duration: 0.2)) {
            selectedTab = .askAI
        }
        Task { await qaController.ask(question) }
    }

    private func scrollAskAIToBottom(_ proxy: ScrollViewProxy) {
        guard selectedTab == .askAI else { return }
        // Wait for the new bubble to be measured, then settle once more after it has.
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
    }

    // MARK: Keyboard shortcuts

    private var keyboardShortcuts: some View {
        ZStack {
            Button("Find in Meeting") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
            ForEach(Array(DetailTab.allCases.enumerated()), id: \.element) { index, tab in
                Button(tab.title) { selectedTab = tab }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Search

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
        return Self.makeTranscriptRows(from: session)
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
        searchedTranscriptRows = rows
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

    private func matchCount(in tab: DetailTab) -> Int {
        guard isSearching else { return 0 }
        switch tab {
        case .summary:
            guard let summary = session.summary else { return 0 }
            var count = KeywordHighlighter.occurrenceCount(in: summary.summaryText, query: keywordQuery)
            for point in summary.keyPoints {
                count += KeywordHighlighter.occurrenceCount(in: point, query: keywordQuery)
            }
            for item in summary.actionItems {
                count += KeywordHighlighter.occurrenceCount(in: item.text, query: keywordQuery)
            }
            return count
        case .transcript:
            return transcriptMatchCount
        case .askAI:
            return (qaController?.messages ?? []).reduce(0) { count, message in
                count + KeywordHighlighter.occurrenceCount(in: message.text, query: keywordQuery)
            }
        }
    }

    private var matchCount: Int {
        DetailTab.allCases.reduce(0) { $0 + matchCount(in: $1) }
    }

    private var searchEmptyState: some View {
        let elsewhere = DetailTab.allCases
            .filter { $0 != selectedTab }
            .compactMap { tab -> (DetailTab, Int)? in
                let count = matchCount(in: tab)
                return count > 0 ? (tab, count) : nil
            }

        return VStack(alignment: .leading, spacing: 12) {
            Text("No matches for “\(keywordQuery)” in \(selectedTab.title).")
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.textSecondary)

            if elsewhere.isEmpty {
                Text("Try a different keyword.")
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
            } else {
                HStack(spacing: 8) {
                    ForEach(elsewhere, id: \.0) { tab, count in
                        DetailPillButton(
                            title: "\(count) in \(tab.title)",
                            systemImage: "arrow.right"
                        ) {
                            selectedTab = tab
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Data

    private func configureControllers() {
        qaController = MeetingQAController(session: session)
        actionItemsController = ActionItemsController(session: session, modelContext: modelContext)
        summaryController = MeetingSummaryController(session: session, modelContext: modelContext)
    }

    private func loadTranscriptRows() {
        transcriptRows = Self.makeTranscriptRows(from: session)
        loadedTranscriptSessionID = session.id
        updateTranscriptSearch()
    }

    private static func makeTranscriptRows(from session: MeetingSession) -> [TranscriptRowModel] {
        session.segments
            .sorted { $0.timestamp < $1.timestamp }
            .map { segment in
                TranscriptRowModel(
                    id: segment.persistentModelID,
                    elapsedText: MeetingMarkdownExporter.elapsedTimestamp(segment.timestamp, since: session.startedAt),
                    clockText: segment.timestamp.formatted(date: .omitted, time: .standard),
                    speaker: segment.speaker,
                    text: segment.text,
                    highlightQuery: ""
                )
            }
    }
}

/// "Share | ⌄": Share opens the macOS share sheet with the meeting as Markdown; the menu has
/// copy, export, archive and delete. Its own view so the Markdown is only rebuilt when the meeting changes.
private struct MeetingShareButton: View {
    let session: MeetingSession
    var onExport: (() -> Void)?
    var onArchive: (() -> Void)?
    var onUnarchive: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            ShareLink(
                item: MeetingMarkdownExporter.markdown(for: session),
                subject: Text(session.displayTitle)
            ) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Share")
                }
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Share this meeting as Markdown")

            Rectangle()
                .fill(AppTheme.border)
                .frame(width: 1, height: 30)

            Menu {
                Button("Copy Summary") {
                    MeetingMarkdownExporter.copyToPasteboard(MeetingMarkdownExporter.summaryMarkdown(for: session))
                }
                .disabled(session.summary == nil)
                Button("Copy Transcript") {
                    MeetingMarkdownExporter.copyToPasteboard(MeetingMarkdownExporter.transcriptText(for: session))
                }
                .disabled(session.segments.isEmpty)
                if let onExport {
                    Button("Export as Markdown…", action: onExport)
                }
                if onArchive != nil || onUnarchive != nil || onDelete != nil {
                    Divider()
                }
                if let onUnarchive {
                    Button("Unarchive", action: onUnarchive)
                }
                if let onArchive {
                    Button("Archive", action: onArchive)
                }
                if let onDelete {
                    Button("Delete", role: .destructive, action: onDelete)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More meeting actions")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(AppTheme.textPrimary)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(AppTheme.bgSidebar))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
        .fixedSize()
    }
}

private enum DetailTab: CaseIterable, Hashable {
    case summary, transcript, askAI

    var title: String {
        switch self {
        case .summary: "Summary"
        case .transcript: "Transcript"
        case .askAI: "Ask AI"
        }
    }
}

private struct SummarySectionHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(AppTheme.textPrimary)
            .padding(.top, 32)
            .padding(.bottom, 12)
    }
}

private struct EmptySummaryCard: View {
    let controller: MeetingSummaryController?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No summary yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text("Generate one from the meeting transcript.")
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
            if let controller {
                if let errorMessage = controller.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.danger)
                }
                GenerateButton(
                    title: "Generate Summary",
                    isGenerating: controller.isGenerating,
                    isProminent: true,
                    isEnabled: controller.canGenerate,
                    onStop: controller.cancel
                ) {
                    controller.start()
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.bgSidebar))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }
}

private struct SummaryFooter: View {
    let generatedAt: Date
    let controller: MeetingSummaryController?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorMessage = controller?.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.danger)
            }
            HStack(spacing: 10) {
                Text("Summary generated \(generatedAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
                if let controller {
                    GenerateButton(
                        title: "Regenerate",
                        isGenerating: controller.isGenerating,
                        isEnabled: controller.canGenerate,
                        onStop: controller.cancel
                    ) {
                        controller.start()
                    }
                }
            }
        }
    }
}

/// Generates, and while it's generating, stops: hovering "Generating…" turns it into Stop.
private struct GenerateButton: View {
    let title: String
    let isGenerating: Bool
    var isProminent = false
    let isEnabled: Bool
    let onStop: () -> Void
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        DetailPillButton(
            title: isGenerating ? (isHovered ? "Stop Generating" : "Generating…") : title,
            systemImage: isGenerating && isHovered ? "stop.fill" : "text.append",
            isProminent: isProminent,
            action: isGenerating ? onStop : action
        )
        .onHover { isHovered = $0 }
        .disabled(!isEnabled && !isGenerating)
        .opacity(isEnabled || isGenerating ? 1 : 0.5)
        .help(isGenerating ? "Stop generating" : "")
    }
}

private struct SessionActionItemsSection: View {
    let items: [ActionItem]
    let controller: ActionItemsController?
    var highlightQuery: String = ""
    var isSearching: Bool = false

    var body: some View {
        SummarySectionHeading(title: "Action Items")
        VStack(alignment: .leading, spacing: 12) {
            if items.isEmpty {
                Text("No action items yet.")
                    .font(.system(size: 14))
                    .foregroundStyle(AppTheme.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
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
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.danger)
                }
                GenerateButton(
                    title: items.isEmpty ? "Generate Action Items" : "Regenerate Action Items",
                    isGenerating: controller.isGenerating,
                    isEnabled: controller.canGenerate,
                    onStop: controller.cancel
                ) {
                    controller.start()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TranscriptRowModel: Identifiable, Equatable {
    let id: PersistentIdentifier
    let elapsedText: String
    let clockText: String
    let speaker: Speaker
    let text: String
    let highlightQuery: String

    func highlighted(with query: String) -> TranscriptRowModel {
        TranscriptRowModel(
            id: id,
            elapsedText: elapsedText,
            clockText: clockText,
            speaker: speaker,
            text: text,
            highlightQuery: query
        )
    }
}

private struct TranscriptRowView: View, Equatable {
    let row: TranscriptRowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(row.speaker.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(row.elapsedText)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.textSecondary)
                    .help(row.clockText)
            }
            HighlightedText(text: row.text, query: row.highlightQuery, font: .system(size: 15))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
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
                font: .system(size: 15),
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
        onContinue: {},
        onArchive: {},
        onExport: {},
        onDelete: {}
    )
    .frame(width: 900, height: 700)
    .preferredColorScheme(.dark)
}
