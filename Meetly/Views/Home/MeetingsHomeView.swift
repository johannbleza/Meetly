import SwiftData
import SwiftUI

enum MeetingListFilter: String, Hashable {
    case meetings, archived
}

enum MeetingListLayout: String, Hashable {
    case list, grid, calendar
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

    @State private var showDeleteAllConfirmation = false

    private static let columnWidth = AppTheme.pageMaxWidth

    private var shownSessions: [MeetingSession] {
        filter == .archived ? archivedSessions : activeSessions
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if filter == .meetings {
                    greetingBand
                }
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

    // MARK: Greeting band

    private var greetingBand: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(greeting)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .offset(y: greetingPush)

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
                    FeaturedMeetingCard(
                        session: featured,
                        isRecording: isRecording(featured),
                        summaryShift: (hero?.summaryShift ?? 0) * heroProgress
                    ) {
                        onOpenFeatured(featured)
                    }
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

    /// "Good evening, Johann." using the first name of the Mac's user account.
    private var greeting: String {
        let salutation = switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
        let firstName = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return firstName.isEmpty ? "\(salutation)." : "\(salutation), \(firstName)."
    }

    /// The meeting being recorded, or else the most recent one.
    private var featuredSession: MeetingSession? {
        if sessionManager.state != .idle, let current = sessionManager.currentSession {
            return current
        }
        return activeSessions.first
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
            if filter == .meetings && !pinnedSessions.isEmpty {
                pinnedSection
            }

            HStack(spacing: 10) {
                AppSectionHeader(title: listTitle)
                Spacer(minLength: 8)
                if filter == .archived && !shownSessions.isEmpty {
                    DetailPillButton(title: "Delete All", systemImage: "trash") {
                        showDeleteAllConfirmation = true
                    }
                }
                AppSegmentedControl(
                    selection: $filter,
                    segments: [
                        .init(value: .meetings, title: "Meetings"),
                        .init(value: .archived, title: "Archived"),
                    ]
                )
                AppSegmentedControl(
                    selection: $layout,
                    segments: [
                        .init(value: .list, systemImage: "list.bullet", help: "List"),
                        .init(value: .grid, systemImage: "square.grid.2x2", help: "Grid"),
                        .init(value: .calendar, systemImage: "calendar", help: "Calendar"),
                    ]
                )
            }
            .padding(.bottom, 16)

            let groups = MeetingActivityGroup.groups(for: shownSessions)
            if layout == .calendar {
                MeetingCalendarView(
                    sessions: shownSessions,
                    month: $calendarMonth,
                    actions: actions(for:),
                    isRecording: isRecording
                )
            } else if groups.isEmpty {
                emptyState
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        Text(group.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary)
                            .padding(.horizontal, layout == .list ? 12 : 0)
                            .padding(.top, group.id == groups.first?.id ? 0 : 24)
                            .padding(.bottom, 8)

                        switch layout {
                        case .list:
                            ForEach(group.sessions) { session in
                                SessionListRowView(session: session, actions: actions(for: session))
                            }
                        case .grid, .calendar:
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 260), spacing: 14)],
                                alignment: .leading,
                                spacing: 14
                            ) {
                                ForEach(group.sessions) { session in
                                    MeetingCardView(session: session, actions: actions(for: session))
                                }
                            }
                        }
                    }
                }
            }
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

    /// Pinned meetings as list rows, above the meetings list, grid or calendar.
    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppSectionHeader(title: "Pinned")
                .padding(.bottom, 8)
            ForEach(pinnedSessions) { session in
                SessionListRowView(session: session, actions: actions(for: session))
            }
        }
        .padding(.bottom, 28)
    }

        private var listTitle: String {
        return filter == .archived ? "Archived meetings" : "All meetings"
    }

    @ViewBuilder
    private var emptyState: some View {
        if filter == .archived {
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

    private func actions(for session: MeetingSession) -> MeetingItemActions {
        MeetingItemActions.standard(
            for: session,
            sessionManager: sessionManager,
            context: modelContext,
            onOpen: { onOpen(session) },
            onDelete: { sessionPendingDelete = session }
        )
    }

    private func deleteAllArchived() {
        let deletable = shownSessions.filter { !sessionManager.isInUse($0) }
        SessionActions.deleteAllArchived(deletable, context: modelContext)
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
                            stops: [.init(color: .black, location: 0.6), .init(color: .black.opacity(0.25), location: 1)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .padding(.top, 6)
                    .offset(y: summaryShift)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .opacity(isHovered ? 0.85 : 1)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onOpen)
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
