import SwiftData
import SwiftUI

enum MeetingListFilter: String, Hashable {
    case meetings, archived
}

enum MeetingListLayout: String, Hashable, CaseIterable {
    case list, grid, calendar

    /// Left to right in the layout control, so switching slides the right way.
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// The home page: a greeting band with the latest (or recording) meeting, then pinned meetings,
/// then every meeting grouped by day as a list, grid or calendar. Search lives in the title bar.
struct MeetingsHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var sessionManager: SessionManager
    let activeSessions: [MeetingSession]
    let archivedSessions: [MeetingSession]
    @Binding var filter: MeetingListFilter
    @Binding var layout: MeetingListLayout
    /// The month shown in the calendar layout; owned by the shell so it survives opening a meeting.
    @Binding var calendarMonth: Date
    let onOpen: (MeetingSession) -> Void
    /// Opening the featured meeting expands its page out of the card.
    let onOpenFeatured: (MeetingSession) -> Void
    /// Where the featured card is, in `MeetingHeroAnchor.coordinateSpace`.
    let featuredAnchor: MeetingHeroAnchor
    @Binding var sessionPendingDelete: MeetingSession?
    /// The featured meeting opening (progress 0 → 1) or closing, as a push: the card rises into
    /// the meeting page's header and pushes the greeting off the top, the list drops away like a
    /// curtain to uncover the page underneath, and the card's summary slides down to the page's.
    var hero: MeetingHeroMotion?

    private var heroProgress: CGFloat { hero?.progress ?? 0 }
    /// How far the curtain (the list and everything under it) has dropped.
    private var curtainDrop: CGFloat { (hero?.curtainDrop ?? 0) * heroProgress }
    /// The greeting and banners go up with the card, and further, out under the title bar.
    private var greetingPush: CGFloat { ((hero?.lift ?? 0) - 90) * heroProgress }

    /// Whether the last layout switch went right in the control (the new layout slides in from
    /// the trailing edge) or left.
    @State private var layoutForward = true
    @State private var showDeleteAllConfirmation = false

    private static let columnWidth = AppTheme.pageMaxWidth
    /// Meetings rendered eagerly at the top of the list (whole day groups until this many). The
    /// featured meeting's curtain slides the list in from below the window, and a lazy stack only
    /// creates rows once they're on screen: rows made mid-slide land at their final spots instead
    /// of riding the curtain up, over the meeting page's text.
    private static let eagerMeetingCount = 30

    private func sessions(for page: MeetingListFilter) -> [MeetingSession] {
        page == .archived ? archivedSessions : activeSessions
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // On both Meetings and Archived; only the list under it slides between them.
                greetingBand
                listSection
            }
            .overlayScrollers()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // See-through while the meeting page is underneath: the band and the curtain cover it.
        .background { AppTheme.bgPrimary.opacity(hero == nil ? 1 : 0) }
        .alert("Delete all archived meetings?", isPresented: $showDeleteAllConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive, action: deleteAllArchived)
        } message: {
            Text("This permanently removes every archived meeting and cannot be undone.")
        }
    }

    /// How far the list slides between Meetings and Archived: the page's width.
    private var pageWidth: CGFloat { featuredAnchor.pageWidth }

    /// Meetings' title sits above Archived's, so each always comes and goes on its own side:
    /// picking Archived rolls "All meetings" up and out and "Archived meetings" up from below.
    private static func titleRoll(_ page: MeetingListFilter) -> AnyTransition {
        let y: CGFloat = page == .meetings ? -22 : 22
        return .asymmetric(insertion: .offset(y: y), removal: .offset(y: y))
    }

    /// Meetings sits to the left of Archived, so each always comes and goes on its own side:
    /// picking Archived slides Meetings out left and Archived in from the right, and back.
    private static func filterSlide(_ page: MeetingListFilter, distance: CGFloat) -> AnyTransition {
        let x = page == .meetings ? -distance : distance
        return .asymmetric(insertion: .offset(x: x), removal: .offset(x: x))
    }

    // MARK: Greeting band

    private var greetingBand: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let errorMessage = sessionManager.errorMessage {
                StatusBanner(message: errorMessage, systemImage: "exclamationmark.octagon", color: AppTheme.danger)
                    .offset(y: greetingPush)
            }
            if let warningMessage = sessionManager.warningMessage {
                StatusBanner(message: warningMessage, systemImage: "exclamationmark.triangle", color: AppTheme.warning)
                    .offset(y: greetingPush)
            }
            if !sessionManager.isAIAvailable {
                StatusBanner(
                    message: sessionManager.aiAvailabilityMessage
                        ?? "Configure \(sessionManager.aiProvider.label) in Settings for AI answers and summaries.",
                    systemImage: "exclamationmark.circle",
                    color: AppTheme.textSecondary
                )
                .offset(y: greetingPush)
            }

            Group {
                if let featured = featuredSession {
                    // A new featured meeting (the latest archived, a meeting pinned) slides in
                    // from the right as the old one slides out left, like the list between
                    // Meetings and Archived, and the band's height glides from one to the other.
                    SlideStack {
                        FeaturedMeetingCard(
                            session: featured,
                            isRecording: isRecording(featured),
                            summaryShift: (hero?.summaryShift ?? 0) * heroProgress,
                            heroProgress: hero == nil ? nil : heroProgress
                        ) {
                            onOpenFeatured(featured)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(featured.id)
                        .transition(.slideAcross(distance: pageWidth))
                    }
                    // Measured outside the slide, so the outgoing card never reports its frame.
                    .offset(y: (hero?.lift ?? 0) * heroProgress)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(MeetingHeroAnchor.coordinateSpace))
                    } action: { frame in
                        // A plain object, so scrolling doesn't re-render the shell.
                        featuredAnchor.frame = frame
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Start a meeting to capture a live transcript, then get a summary and action items when it ends.")
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: Self.columnWidth, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 30)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity)
        // The band's tint gives way to the meeting page's background under it.
        .background { AppTheme.bgBand.opacity(1 - heroProgress) }
        .overlay(alignment: .bottom) {
            AppDivider(axis: .horizontal)
                .offset(y: curtainDrop)
        }
    }

    /// The meeting being recorded, or else the most recently pinned one (the top of Pinned), or
    /// else the latest one. Pinning, unpinning and archiving slide the card to the new one.
    private var featuredSession: MeetingSession? {
        if sessionManager.state != .idle, let current = sessionManager.currentSession {
            return current
        }
        return pinnedSessions.first ?? activeSessions.first
    }

    private func isRecording(_ session: MeetingSession) -> Bool {
        sessionManager.state != .idle && sessionManager.currentSession?.id == session.id
    }

    private var pinnedSessions: [MeetingSession] {
        activeSessions
            .filter(\.isPinned)
            .sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
    }

    // MARK: List

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The header stays put. Its title rolls inside its own line, like a ticker: up to
            // Archived, down back to Meetings.
            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    AppSectionHeader(title: listTitle(filter))
                        .fixedSize()
                        .id(filter)
                        .transition(Self.titleRoll(filter))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                listControls
            }
            .padding(.bottom, 16)

            // Slides sideways between Meetings and Archived, and by direction between layouts.
            VStack(alignment: .leading, spacing: 0) {
                if filter == .meetings && layout == .grid {
                    pinnedSection
                }
                layoutContent(filter)
                    .id(layout)
                    .transition(.slide(forward: layoutForward, distance: pageWidth))
            }
            // Part of the Archived list, on its first heading's line, so it slides in and out
            // with the list rather than waiting in the header.
            .overlay(alignment: .topTrailing) {
                if filter == .archived && layout != .calendar && !archivedSessions.isEmpty {
                    DetailPillButton(title: "Delete All", systemImage: "trash") {
                        showDeleteAllConfirmation = true
                    }
                    // Centered on the heading's line (13 pt text, the pill is 28 pt).
                    .offset(y: -6)
                    .transition(.slide(forward: layoutForward, distance: pageWidth))
                }
            }
            .id(filter)
            .transition(Self.filterSlide(filter, distance: pageWidth))
        }
        .frame(maxWidth: Self.columnWidth, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity)
        // The curtain: opaque down past the window's bottom, so it hides the meeting page under
        // it until it drops away.
        .background(alignment: .top) {
            AppTheme.bgPrimary.frame(height: 10_000)
        }
        .offset(y: curtainDrop)
    }

    /// The Meetings / Archived filter and the list / grid / calendar switch.
    private var listControls: some View {
        HStack(spacing: 10) {
            AppSegmentedControl(
                selection: $filter,
                segments: [
                    .init(value: .meetings, title: "Meetings"),
                    .init(value: .archived, title: "Archived"),
                ],
                animation: AppMotion.resolved(AppMotion.pager)
            )
            .zIndex(1)
            AppSegmentedControl(
                selection: layoutSelection,
                segments: [
                    .init(value: .list, systemImage: "list.bullet", help: "List"),
                    .init(value: .grid, systemImage: "square.grid.2x2", help: "Grid"),
                    .init(value: .calendar, systemImage: "calendar", help: "Calendar"),
                ],
                animation: nil
            )
            .zIndex(1)
        }
        .fixedSize()
    }

    /// Sets the slide direction first, then switches the layout, so the old layout leaves
    /// toward the side the new one isn't coming from.
    private var layoutSelection: Binding<MeetingListLayout> {
        Binding {
            layout
        } set: { newValue in
            guard newValue != layout else { return }
            let forward = newValue.order > layout.order
            let changed = forward != layoutForward
            layoutForward = forward
            AppMotion.afterDirection(changed: changed, AppMotion.content) { layout = newValue }
        }
    }

    @ViewBuilder
    private func layoutContent(_ page: MeetingListFilter) -> some View {
        let shown = sessions(for: page)
        // Pinned meetings show in the Pinned list instead of their day, so pinning moves the row
        // up rather than copying it (the calendar still shows every meeting on its day).
        let groups = MeetingActivityGroup.groups(for: page == .meetings ? shown.filter { !$0.isPinned } : shown)
        let pinned = page == .meetings ? pinnedSessions : []
        if layout == .calendar {
            MeetingCalendarView(
                sessions: shown,
                month: $calendarMonth,
                actions: actions(for:),
                isRecording: isRecording
            )
        } else if groups.isEmpty && pinned.isEmpty {
            emptyState(page)
        } else if layout == .list {
            flatList(Self.listItems(shown, pinned: pinned, separatingPinned: page == .meetings, shows: PinStaging.shared.headingShows))
        } else {
            let split = Self.eagerSplit(groups)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(split.head) { group in
                        groupView(group, isFirst: group.id == groups.first?.id)
                    }
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(split.tail) { group in
                        groupView(group, isFirst: false)
                    }
                }
            }
        }
    }

    /// The list layout as one run of headings and rows, Pinned first. One `ForEach` keyed by
    /// meeting, so pinning or unpinning reorders a row and SwiftUI moves it (up into Pinned, back
    /// down into its day) instead of removing one copy and inserting another.
    private static func listItems(
        _ sessions: [MeetingSession],
        pinned: [MeetingSession],
        separatingPinned: Bool,
        shows: (MeetingSession) -> Bool
    ) -> [MeetingListItem] {
        // Rows follow the saved pin; headings follow the staged one (`PinStaging`), so while a
        // pin is staged the heading the row is leaving rolls away (or the one it's heading for
        // opens) before the row moves.
        var items: [MeetingListItem] = []
        let inDays = separatingPinned ? sessions.filter { !$0.isPinned || !shows($0) } : sessions
        let days = MeetingActivityGroup.groups(for: inDays)
        func hasHeading(_ group: MeetingActivityGroup) -> Bool {
            !separatingPinned || group.sessions.contains { !shows($0) }
        }
        // Unpinning the last pinned meeting into the top day: that day's heading takes the Pinned
        // heading's line (one rolls out as the other rolls in, like the list title) instead of
        // opening under the row, which then has nowhere to move. The mirror of pinning the top
        // day's only meeting, where Pinned rolls in as the day rolls out.
        var leadingDay: String?
        if separatingPinned {
            if sessions.contains(where: shows) {
                items.append(.heading(id: "pinned", title: "Pinned", isFirst: true))
            } else if let first = days.first, hasHeading(first), first.sessions.contains(where: \.isPinned) {
                items.append(.heading(id: first.id, title: first.title, isFirst: true))
                leadingDay = first.id
            }
            items += pinned.map { .row($0) }
        }
        for group in days {
            if hasHeading(group) && group.id != leadingDay {
                items.append(.heading(id: group.id, title: group.title, isFirst: items.isEmpty))
            }
            items += group.sessions.filter { !separatingPinned || !$0.isPinned }.map { .row($0) }
        }
        return items
    }

    @ViewBuilder
    private func flatList(_ items: [MeetingListItem]) -> some View {
        // Eager head, lazy tail, as with the day groups (see `eagerMeetingCount`).
        let split = Self.eagerSplit(items)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(split.head) { flatItem($0) }
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(split.tail) { flatItem($0) }
            }
        }
    }

    @ViewBuilder
    private func flatItem(_ item: MeetingListItem) -> some View {
        switch item {
        case .heading(_, let title, let isFirst):
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.top, isFirst ? 0 : 24)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.rollLine(up: true))
        case .row(let session):
            SessionListRowView(session: session, actions: actions(for: session))
                .transition(.rollLine(up: true))
        }
    }

    private static func eagerSplit(_ items: [MeetingListItem]) -> (head: [MeetingListItem], tail: [MeetingListItem]) {
        var rows = 0
        var index = 0
        while index < items.count {
            if case .heading = items[index], rows >= eagerMeetingCount { break }
            if case .row = items[index] { rows += 1 }
            index += 1
        }
        return (Array(items[..<index]), Array(items[index...]))
    }

    /// Whole day groups from the top until `eagerMeetingCount` meetings, then the rest.
    private static func eagerSplit(_ groups: [MeetingActivityGroup]) -> (head: [MeetingActivityGroup], tail: [MeetingActivityGroup]) {
        var count = 0
        var index = 0
        while index < groups.count && count < eagerMeetingCount {
            count += groups[index].sessions.count
            index += 1
        }
        return (Array(groups[..<index]), Array(groups[index...]))
    }

    @ViewBuilder
    private func groupView(_ group: MeetingActivityGroup, isFirst: Bool) -> some View {
        Text(group.title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.horizontal, layout == .list ? 12 : 0)
            .padding(.top, isFirst ? 0 : 24)
            .padding(.bottom, 8)

        switch layout {
        case .list:
            ForEach(group.sessions) { session in
                SessionListRowView(session: session, actions: actions(for: session))
            }
        case .grid, .calendar:
            // A plain grid rather than `LazyVGrid`: a group's cards are few, and lazy cells
            // would miss the curtain's slide like lazy rows do (see `eagerMeetingCount`).
            AdaptiveCardGrid(minimumWidth: 260, spacing: 14) {
                ForEach(group.sessions) { session in
                    MeetingCardView(session: session, actions: actions(for: session))
                        // No fade when pinning takes a card out: the others close the gap.
                        .transition(.identity)
                }
            }
        }
    }

    /// Pinned meetings as list rows, above the meetings list, grid or calendar.
    /// Always in the Meetings page, collapsed to nothing with no pins, so the first pin opens it
    /// (the list below glides down) and the heading rolls up into its clipped line, like the list
    /// title, instead of fading in. The last unpin rolls it up and out as the section closes.
    private var pinnedSection: some View {
        let hasPins = !pinnedSessions.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if hasPins {
                    // Under the list's header now, so styled like a day's heading.
                    Text("Pinned")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .transition(.asymmetric(insertion: .offset(y: 22), removal: .offset(y: -22)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: hasPins ? nil : 0, alignment: .top)
            .clipped()
            ForEach(pinnedSessions) { session in
                SessionListRowView(session: session, actions: actions(for: session))
                    .transition(.rollLine(up: true))
            }
        }
        .padding(.bottom, hasPins ? 24 : 0)
    }

    private func listTitle(_ page: MeetingListFilter) -> String {
        page == .archived ? "Archived meetings" : "All meetings"
    }

    @ViewBuilder
    private func emptyState(_ page: MeetingListFilter) -> some View {
        if page == .archived {
            MeetingActivityEmptyState(
                systemImage: "archivebox",
                title: "No archived meetings",
                message: "Archived meetings will appear here."
            )
        } else {
            MeetingActivityEmptyState(
                systemImage: "calendar.badge.clock",
                title: "No meetings yet",
                message: "Start a meeting to capture transcripts and summaries."
            )
        }
    }

    /// Every archived meeting except one being recorded into. The rows roll away as the list
    /// closes up.
    private func deleteAllArchived() {
        let deletable = archivedSessions.filter { !sessionManager.isInUse($0) }
        withAnimation(AppMotion.resolved(AppMotion.content)) {
            SessionActions.deleteAllArchived(deletable, context: modelContext)
        }
    }

    private func actions(for session: MeetingSession) -> MeetingItemActions {
        MeetingItemActions.standard(
            for: session,
            sessionManager: sessionManager,
            context: modelContext,
            onOpen: { onOpen(session) },
            onDelete: { sessionPendingDelete = session }
        )
    }
}

/// Cards in as many columns of at least `minimumWidth` as fit, rows as tall as their tallest
/// card and centered in it, like an adaptive `LazyVGrid`, but laid out eagerly.
private struct AdaptiveCardGrid: Layout {
    let minimumWidth: CGFloat
    let spacing: CGFloat

    private func columns(for width: CGFloat) -> Int {
        max(1, Int((width + spacing) / (minimumWidth + spacing)))
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> (itemWidth: CGFloat, heights: [CGFloat], columns: Int) {
        let columns = columns(for: width)
        let itemWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var heights: [CGFloat] = []
        for start in stride(from: 0, to: subviews.count, by: columns) {
            let row = subviews[start..<min(start + columns, subviews.count)]
            heights.append(row.map { $0.sizeThatFits(.init(width: itemWidth, height: nil)).height }.max() ?? 0)
        }
        return (itemWidth, heights, columns)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimumWidth
        let layout = rows(subviews, width: width)
        let height = layout.heights.reduce(0, +) + spacing * CGFloat(max(0, layout.heights.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = rows(subviews, width: bounds.width)
        var y = bounds.minY
        for (rowIndex, rowHeight) in layout.heights.enumerated() {
            for column in 0..<layout.columns {
                let index = rowIndex * layout.columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (layout.itemWidth + spacing)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + rowHeight / 2),
                    anchor: .leading,
                    proposal: .init(width: layout.itemWidth, height: nil)
                )
            }
            y += rowHeight + spacing
        }
    }
}

/// The large "latest meeting" entry in the greeting band. Styled like the top of the meeting page
/// (`SessionDetailView.header` and its summary), so opening it expands into that page without
/// switching designs.
private struct FeaturedMeetingCard: View {
    let session: MeetingSession
    let isRecording: Bool
    /// The meeting page shows its summary below its tabs, so it slides down as the card opens.
    var summaryShift: CGFloat = 0
    /// While it opens into (or closes from) the meeting page, which hides its own summary until
    /// then: this summary stands in for it, so its fade-out melts away as it lands.
    var heroProgress: CGFloat?
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            metadataLine
                // The meeting page's metadata row is as tall as its Share button.
                .frame(height: 30, alignment: .leading)

            Text(session.displayTitle)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(2)

            if let summary = session.summary?.summaryText, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 15))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineSpacing(5)
                    .lineLimit(3)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0.6),
                                .init(color: .black.opacity(0.25 + 0.75 * (heroProgress ?? 0)), location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .padding(.top, 6)
                    .offset(y: summaryShift)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        // Full strength while it stands in for the meeting page's header.
        .opacity(isHovered && heroProgress == nil ? 0.85 : 1)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onOpen)
        .clickableCursor()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// Same as the meeting page's: "Friday, Nov 13 • 7:45 PM • 3m".
    private var metadataLine: some View {
        HStack(spacing: 6) {
            if isRecording {
                Circle().fill(AppTheme.danger).frame(width: 7, height: 7)
                Text("Recording now")
                    .foregroundStyle(AppTheme.danger)
                Text("•")
            }
            Text(session.startedAt.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
            Text("•")
            Text(session.startedAt.formatted(date: .omitted, time: .shortened))
            if !isRecording, let duration = shortDuration {
                Text("•")
                Text(duration)
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
}

private struct StatusBanner: View {
    let message: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            Text(message)
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.bgSidebar))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }
}

/// A heading or a meeting row in the flat list layout.
private enum MeetingListItem: Identifiable {
    case heading(id: String, title: String, isFirst: Bool)
    case row(MeetingSession)

    var id: String {
        switch self {
        case .heading(let id, _, _): "heading-" + id
        case .row(let session): session.id.uuidString
        }
    }
}

extension AnyTransition {
    /// A line that opens and closes instead of fading: its height grows from zero (the lines below
    /// glide down to make room) while the content rolls into the clipped line, and the reverse on
    /// the way out. `up`: comes in from below and leaves upward.
    static func rollLine(up: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: RollLine(fraction: 0, from: up ? 1 : -1), identity: RollLine(fraction: 1, from: up ? 1 : -1)),
            removal: .modifier(active: RollLine(fraction: 0, from: up ? -1 : 1), identity: RollLine(fraction: 1, from: up ? -1 : 1))
        )
    }
}

private struct RollLine: ViewModifier {
    var fraction: CGFloat
    /// +1: the content sits below the line while closed, −1 above.
    var from: CGFloat

    func body(content: Content) -> some View {
        RollLineLayout(fraction: fraction, from: from) { content }
            .clipped()
    }
}

/// Reports `fraction` of its content's height and slides the content by the rest, so the line
/// opens and closes in the layout (an offset alone would leave the space in place).
private struct RollLineLayout: Layout {
    var fraction: CGFloat
    var from: CGFloat

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? size.width, height: size.height * max(0, fraction))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let shift = from * (1 - fraction) * size.height
        child.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + shift),
            proposal: ProposedViewSize(width: bounds.width, height: size.height)
        )
    }
}

extension AnyTransition {
    /// In from the right, out to the left, `distance` points, with no fade. The view's height
    /// grows from zero on the way in and shrinks to zero on the way out, so in a `SlideStack`
    /// the height glides from the old view's to the new one's.
    static func slideAcross(distance: CGFloat) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: SlideAcross(fraction: 0, x: distance), identity: SlideAcross(fraction: 1, x: distance)),
            removal: .modifier(active: SlideAcross(fraction: 0, x: -distance), identity: SlideAcross(fraction: 1, x: -distance))
        )
    }
}

private struct SlideAcross: ViewModifier {
    var fraction: CGFloat
    /// Where the view sits while it's out.
    var x: CGFloat

    func body(content: Content) -> some View {
        SlideAcrossLayout(fraction: fraction, x: x) { content }
    }
}

/// Reports `fraction` of its content's height and offsets the content by the rest of `x`. The
/// content is placed at its full height, so it hangs below while the reported height is short.
private struct SlideAcrossLayout: Layout {
    var fraction: CGFloat
    var x: CGFloat

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? size.width, height: size.height * max(0, fraction))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        child.place(
            at: CGPoint(x: bounds.minX + x * (1 - fraction), y: bounds.minY),
            proposal: ProposedViewSize(width: bounds.width, height: size.height)
        )
    }
}

/// Lays its views over each other at the top, as tall as their heights added up: with
/// `slideAcross`, the outgoing view's height shrinks as the incoming one's grows, so the stack's
/// height glides from one to the other. At rest it holds one view.
private struct SlideStack: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        return CGSize(
            width: proposal.width ?? sizes.map(\.width).max() ?? 0,
            height: sizes.map(\.height).reduce(0, +)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}
