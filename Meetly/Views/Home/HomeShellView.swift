import SwiftData
import SwiftUI

/// The main window: a title bar (back / forward, meeting search, the meeting control and Settings)
/// over one full-width page, either the home list or a meeting. Settings has its own window.
struct HomeShellView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Bindable var sessionManager: SessionManager

    @Query(
        filter: #Predicate<MeetingSession> { session in
            session.isArchived == false || session.isArchived == nil
        },
        sort: \MeetingSession.startedAt,
        order: .reverse
    )
    private var activeSessions: [MeetingSession]

    @Query(
        filter: #Predicate<MeetingSession> { $0.isArchived == true },
        sort: \MeetingSession.startedAt,
        order: .reverse
    )
    private var archivedSessions: [MeetingSession]

    private enum Route: Hashable {
        case home
        case meeting(UUID)
    }

    @State private var route: Route = .home
    @State private var backStack: [Route] = []
    @State private var forwardStack: [Route] = []
    @State private var search = SidebarSearchModel()
    /// ⌘K or the title-bar pill: the page is replaced by a large search field over the results.
    @State private var isSearchMode = false
    @State private var listFilter: MeetingListFilter = .meetings
    @AppStorage("meetingListLayout") private var listLayout: MeetingListLayout = .list
    @State private var calendarMonth = Date.now
    /// Bumped by ⌘K so pressing it again in search mode refocuses the field.
    @State private var searchFocusRequest = 0
    /// Morphs the title-bar pill into search mode's field and back.
    @State private var searchMorph = SearchMorphDriver()
    /// The search field and results show once the pill has morphed into the field.
    @State private var isSearchRevealed = false
    @State private var sessionPendingDelete: MeetingSession?
    @State private var showDeleteConfirmation = false
    @State private var mouseNavigation = MouseNavigationMonitor()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The featured card's frame, written by the home page as it lays out.
    @State private var heroAnchor = MeetingHeroAnchor()
    /// The meeting opened from the featured card: the home page fades away around the card as
    /// it rises into the meeting page's header, and going back reverses it.
    @State private var heroSessionID: UUID?
    /// Distances for the push, measured when it starts.
    @State private var heroMetrics = MeetingHeroMotion()
    /// 0 is the home page, 1 the meeting page.
    @State private var heroProgress: CGFloat = 1
    /// Keeps the home page over the meeting page while the card rises or falls back.
    @State private var isHeroAnimating = false

    private static let heroSpring = Animation.spring(duration: 0.5, bounce: 0.12)

    private var allSessions: [MeetingSession] {
        activeSessions + archivedSessions
    }

    private var openSession: MeetingSession? {
        guard case .meeting(let id) = route else { return nil }
        return allSessions.first { $0.id == id }
    }

    var body: some View {
        ZStack {
            pageContent
            // Above the meeting page: while the featured meeting opens, the home page fades away
            // around its card, uncovering the meeting page underneath.
            homePage
        }
            .coordinateSpace(.named(MeetingHeroAnchor.coordinateSpace))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heroAnchor.pageHeight = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .appPanelBackground(AppTheme.bgPrimary)
            .overlay {
                // Under the toolbar too, so the morph can start and end on the title-bar pill.
                SearchMorphLayer(model: searchMorph.model)
                    .background(LiquidAnchorView(anchor: searchMorph.canvas))
                    .ignoresSafeArea()
            }
            .toolbar { titleBar }
            .toolbar(removing: .title)
            .toolbarBackground(AppTheme.bgPrimary, for: .windowToolbar)
            // Hidden (it's the same color as the page) while searching, so the morph shows
            // through where the pill was.
            .toolbarBackgroundVisibility(
                isSearchMode || searchMorph.model.isRunning ? .hidden : .visible,
                for: .windowToolbar
            )
            .background(alignment: .topLeading) { keyboardShortcuts }
            .onAppear {
                search.attach(to: modelContext.container)
                mouseNavigation.start(back: goBack, forward: goForward)
            }
            .onDisappear {
                mouseNavigation.stop()
            }
            .onChange(of: allSessions.count) { _, _ in
                search.meetingsChanged()
            }
            .onChange(of: activeSessions.map(\.id)) { _, _ in
                validateRoutes()
            }
            .onChange(of: archivedSessions.map(\.id)) { _, _ in
                validateRoutes()
            }
            .onChange(of: sessionManager.lastCompletedSessionID) { _, sessionID in
                guard let sessionID else { return }
                closeSearch(animated: false)
                listFilter = .meetings
                navigate(to: .meeting(sessionID))
            }
            .onChange(of: sessionPendingDelete) { _, newValue in
                showDeleteConfirmation = newValue != nil
            }
            .alert("Delete meeting?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    sessionPendingDelete = nil
                }
                Button("Delete", role: .destructive) {
                    deletePendingSession()
                }
            } message: {
                Text("This permanently removes the meeting and its transcript. This cannot be undone.")
            }
    }

    // MARK: Pages

    /// Its own slot, so it stays alive (and keeps its scroll position) while a meeting page
    /// expands over it.
    @ViewBuilder
    private var homePage: some View {
        if !isSearchMode && (openSession == nil || isHeroAnimating) {
            MeetingsHomeView(
                sessionManager: sessionManager,
                activeSessions: activeSessions,
                archivedSessions: archivedSessions,
                filter: $listFilter,
                layout: $listLayout,
                calendarMonth: $calendarMonth,
                onOpen: { navigate(to: .meeting($0.id)) },
                onOpenFeatured: openFeatured,
                featuredAnchor: heroAnchor,
                sessionPendingDelete: $sessionPendingDelete,
                hero: isHeroAnimating ? heroMotion : nil
            )
            .allowsHitTesting(!isHeroAnimating)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        if isSearchMode {
            MeetingSearchView(
                search: search,
                sessions: allSessions.sorted { $0.startedAt > $1.startedAt },
                focusRequest: searchFocusRequest,
                isRevealed: isSearchRevealed,
                fieldAnchor: searchMorph.field,
                onFieldLaidOut: morphPillIntoField,
                actions: { session in
                    itemActions(for: session) {
                        closeSearch(animated: false)
                        navigate(to: .meeting(session.id))
                    }
                },
                onClose: { closeSearch() }
            )
            .transition(.opacity)
        } else if let openSession {
            SessionDetailView(
                session: openSession,
                onContinue: sessionManager.state == .idle ? {
                    Task { await sessionManager.continueMeeting(openSession) }
                } : nil,
                onArchive: openSession.isArchivedValue || sessionManager.isInUse(openSession) ? nil : {
                    archiveSession(openSession)
                },
                onUnarchive: openSession.isArchivedValue ? {
                    unarchiveSession(openSession)
                } : nil,
                onExport: {
                    MeetingMarkdownExporter.export(openSession)
                },
                onDelete: sessionManager.isInUse(openSession) ? nil : {
                    sessionPendingDelete = openSession
                },
                hero: isHeroAnimating && heroSessionID == openSession.id ? heroMotion : nil,
                heroAnchor: heroAnchor
            )
            .allowsHitTesting(!isHeroAnimating)
            .id(openSession.id)
        }
    }

    // MARK: Title bar

    @ToolbarContentBuilder
    private var titleBar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            TitleBarIconButton(systemImage: "chevron.left", help: "Back (⌘[)", action: goBack)
                .disabled(backStack.isEmpty && !isSearchMode)
            TitleBarIconButton(systemImage: "chevron.right", help: "Forward (⌘])", action: goForward)
                .disabled(forwardStack.isEmpty)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .principal) {
            // The pill becomes search mode's field, so it's hidden while the morph runs and
            // while the field shows (still laid out, so it can be measured). It stays until the
            // morph starts, so there's no blank frame in between.
            TitleBarSearchButton(
                anchor: searchMorph.pill,
                isHidden: (isSearchMode && isSearchRevealed) || searchMorph.model.isRunning,
                action: openSearch
            )
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItemGroup(placement: .primaryAction) {
            ActiveMeetingControls(sessionManager: sessionManager)
            Button {
                SettingsWindow.open(with: openWindow)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(AppTheme.bgInput))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
        .sharedBackgroundVisibility(.hidden)
    }

    private var keyboardShortcuts: some View {
        ZStack {
            Button("Search Meetings", action: openSearch)
                .keyboardShortcut("k", modifiers: .command)
            Button("Back", action: goBack)
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward", action: goForward)
                .keyboardShortcut("]", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Navigation

    private func openSearch() {
        searchFocusRequest += 1
        guard !isSearchMode else { return }
        isSearchRevealed = false
        withAnimation(.easeOut(duration: 0.15)) { isSearchMode = true }
        // The morph starts once the search field is laid out (`morphPillIntoField`).
    }

    private func morphPillIntoField() {
        guard isSearchMode, !isSearchRevealed else { return }
        searchMorph.open {
            withAnimation(.easeOut(duration: 0.16)) { isSearchRevealed = true }
        }
    }

    /// Leaves search mode. Animated, the field morphs back into the title-bar pill.
    private func closeSearch(animated: Bool = true) {
        guard isSearchMode else { return }
        if animated {
            // Before the page changes, while the field can still be measured.
            searchMorph.close {}
        } else {
            searchMorph.reset()
        }
        isSearchRevealed = false
        withAnimation(.easeOut(duration: 0.18)) { isSearchMode = false }
        search.text = ""
    }

    private func navigate(to newRoute: Route) {
        guard newRoute != route else { return }
        heroSessionID = nil
        backStack.append(route)
        forwardStack.removeAll()
        route = newRoute
    }

    /// Opens the featured meeting: the card rises into the page's header and pushes the home page
    /// away around it.
    private func openFeatured(_ session: MeetingSession) {
        guard !isHeroAnimating else { return }
        let source = heroAnchor.frame
        navigate(to: .meeting(session.id))
        guard !reduceMotion, source.width > 0, source.height > 0 else { return }
        heroSessionID = session.id
        heroMetrics = measuredHeroMetrics()
        heroProgress = 0
        isHeroAnimating = true
        // Once the meeting page under the home page is laid out, so its header and tabs can be
        // measured, and then a frame later, so the motion starts from those measurements.
        DispatchQueue.main.async {
            heroMetrics = measuredHeroMetrics()
            DispatchQueue.main.async {
                withAnimation(Self.heroSpring, completionCriteria: .removed) {
                    heroProgress = 1
                } completion: {
                    isHeroAnimating = false
                }
            }
        }
    }

    /// Back from a meeting opened from the featured card: the push in reverse, and the header
    /// settles back down into the card.
    private func collapseIntoFeatured() {
        // The card's last frame for now; remeasured once the home page under it is laid out.
        heroMetrics = measuredHeroMetrics()
        heroProgress = 1
        isHeroAnimating = true
        DispatchQueue.main.async {
            guard heroAnchor.frame.height > 0 else {
                finishCollapse()
                return
            }
            heroMetrics = measuredHeroMetrics()
            withAnimation(Self.heroSpring, completionCriteria: .removed) {
                heroProgress = 0
            } completion: {
                finishCollapse()
            }
        }
    }

    private func finishCollapse() {
        if backStack.last == .home {
            backStack.removeLast()
            forwardStack.append(route)
            route = .home
        }
        heroSessionID = nil
        heroProgress = 1
        isHeroAnimating = false
    }

    private var heroMotion: MeetingHeroMotion {
        var motion = heroMetrics
        motion.progress = heroProgress
        return motion
    }

    private func measuredHeroMetrics() -> MeetingHeroMotion {
        MeetingHeroMotion(
            lift: heroAnchor.pageHeaderTop - heroAnchor.frame.minY,
            tabBlockHeight: heroAnchor.tabBlockHeight,
            curtainDrop: heroAnchor.pageHeight
        )
    }

    private func goBack() {
        guard !isHeroAnimating else { return }
        if isSearchMode {
            closeSearch()
            return
        }
        if !reduceMotion, let heroSessionID, route == .meeting(heroSessionID), backStack.last == .home {
            collapseIntoFeatured()
            return
        }
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(route)
        route = previous
    }

    private func goForward() {
        guard !isHeroAnimating, !isSearchMode, let next = forwardStack.popLast() else { return }
        backStack.append(route)
        route = next
    }

    /// Drops history entries for meetings that no longer exist, and leaves a deleted meeting's page.
    private func validateRoutes() {
        let ids = Set(allSessions.map(\.id))
        func isValid(_ route: Route) -> Bool {
            if case .meeting(let id) = route { return ids.contains(id) }
            return true
        }
        backStack.removeAll { !isValid($0) }
        forwardStack.removeAll { !isValid($0) }
        // Collapse repeats left behind by removed entries.
        backStack = backStack.reduce(into: []) { result, entry in
            if result.last != entry { result.append(entry) }
        }
        if !isValid(route) {
            route = .home
            if backStack.last == .home { backStack.removeLast() }
        }
    }

    // MARK: Actions

    private func itemActions(for session: MeetingSession, onOpen: @escaping () -> Void) -> MeetingItemActions {
        MeetingItemActions.standard(
            for: session,
            sessionManager: sessionManager,
            context: modelContext,
            onOpen: onOpen,
            onDelete: { sessionPendingDelete = session }
        )
    }

    private func archiveSession(_ session: MeetingSession) {
        guard !sessionManager.isInUse(session) else { return }
        SessionActions.archive(session, context: modelContext)
        navigate(to: .home)
    }

    private func unarchiveSession(_ session: MeetingSession) {
        SessionActions.unarchive(session, context: modelContext)
        navigate(to: .home)
    }

    private func deletePendingSession() {
        guard let sessionPendingDelete else { return }
        // A recording may have started on this meeting while the confirmation was open.
        guard !sessionManager.isInUse(sessionPendingDelete) else {
            self.sessionPendingDelete = nil
            return
        }
        SessionActions.delete(sessionPendingDelete, context: modelContext)
        self.sessionPendingDelete = nil
    }
}

/// Positions the featured-meeting push aims for. A plain object rather than state: the card's
/// frame changes as the home page scrolls, and that mustn't re-render the shell.
final class MeetingHeroAnchor {
    static let coordinateSpace = "meetingHeroPage"
    /// The featured card's frame (its last one, once the home page is gone).
    var frame: CGRect = .zero
    /// The meeting page's header top and its tab bar's height, padding included.
    var pageHeaderTop: CGFloat = 28
    var tabBlockHeight: CGFloat = 76
    var pageHeight: CGFloat = 800
}

/// The featured meeting opening (progress 0 → 1) or closing. The card is styled like the meeting
/// page's header, so it rises `lift` points to become it, pushing the greeting off the top. The
/// home page's list drops `curtainDrop` points like a curtain, uncovering the meeting page under
/// it. The tabs open in the gap between the title and the summary, so the summary moves down by
/// `summaryShift` from the card's spot to the page's.
struct MeetingHeroMotion {
    /// The card's gap between its title and summary (stack spacing plus summary padding).
    static let cardSummaryGap: CGFloat = 14

    var progress: CGFloat = 0
    var lift: CGFloat = 0
    var tabBlockHeight: CGFloat = 76
    var curtainDrop: CGFloat = 800

    var summaryShift: CGFloat { tabBlockHeight - Self.cardSummaryGap }
}

/// Maps a mouse's side buttons (button 4 back, button 5 forward) to the main window's history.
@MainActor
private final class MouseNavigationMonitor {
    private var monitor: Any?

    func start(back: @escaping () -> Void, forward: @escaping () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { event in
            // Only in the main window, so Settings and the overlay keep their own behavior.
            guard MainWindowController.shared.isMainWindow(event.window) else { return event }
            switch event.buttonNumber {
            case 3:
                back()
                return nil
            case 4:
                forward()
                return nil
            default:
                return event
            }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

/// The centered search pill in the title bar. Clicking it (or ⌘K) morphs it into search
/// mode's large field.
private struct TitleBarSearchButton: View {
    let anchor: LiquidAnchor
    let isHidden: Bool
    let action: () -> Void

    @State private var isHovered = false

    // Built around a real TextField: the toolbar's principal slot drops items without a
    // control in them (plain views and Buttons never render there). The field only shows the
    // placeholder; clicks open search mode, whose own field takes the typing.
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
            TextField("Search meetings", text: .constant(""))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focusable(false)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Text("⌘K")
                .font(.system(size: 11, weight: .medium))
                .opacity(0.8)
        }
        .foregroundStyle(AppTheme.textSecondary)
        .padding(.horizontal, 12)
        .frame(width: 460, height: 30)
        // The morph's color, so the hand-off to and from it is seamless; hover only outlines.
        .background(RoundedRectangle(cornerRadius: SearchMorphDriver.pillCorner, style: .continuous).fill(AppTheme.bgInput))
        .overlay(
            RoundedRectangle(cornerRadius: SearchMorphDriver.pillCorner, style: .continuous)
                .stroke(isHovered ? AppTheme.border : .clear, lineWidth: 1)
        )
        .background(LiquidAnchorView(anchor: anchor))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { isHovered = $0 }
        // Swapped with the morph in the same frame, so no animation.
        .opacity(isHidden ? 0 : 1)
        .transaction { $0.animation = nil }
        .allowsHitTesting(!isHidden)
        .help("Search meetings (⌘K)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Search meetings")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

private struct TitleBarIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isEnabled ? AppTheme.textPrimary : AppTheme.textSecondary.opacity(0.5))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovered && isEnabled ? AppTheme.bgHover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

#Preview {
    HomeShellView(sessionManager: SessionManager())
        .frame(width: 1100, height: 720)
        .modelContainer(for: [MeetingSession.self, TranscriptSegment.self, MeetingSummary.self, ActionItem.self], inMemory: true)
}
