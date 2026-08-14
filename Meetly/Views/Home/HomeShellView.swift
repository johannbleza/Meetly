import SwiftData
import SwiftUI

struct HomeShellView: View {
    @Environment(\.modelContext) private var modelContext
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
        sort: \MeetingSession.archivedAt,
        order: .reverse
    )
    private var archivedSessions: [MeetingSession]

    @State private var selectedPanel: HomePanel = .meetings
    @State private var selectedSessionID: UUID?
    @State private var sidebarSearchText = ""
    @State private var sessionPendingDelete: MeetingSession?
    @State private var showDeleteConfirmation = false

    private var allSessions: [MeetingSession] {
        activeSessions + archivedSessions
    }

    private var selectedSession: MeetingSession? {
        guard let selectedSessionID else { return nil }
        return allSessions.first { $0.id == selectedSessionID }
    }

    var body: some View {
        HStack(spacing: 0) {
            ActivityBarView(selectedPanel: $selectedPanel)
            AppDivider()

            sidebarContent
            AppDivider()

            detailContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appPanelBackground(AppTheme.bgPrimary)
        .onChange(of: selectedPanel) { _, newPanel in
            if newPanel == .settings {
                selectedSessionID = nil
            }
        }
        .onChange(of: activeSessions.map(\.id)) { _, _ in
            validateSelection()
        }
        .onChange(of: archivedSessions.map(\.id)) { _, _ in
            validateSelection()
        }
        .onChange(of: sessionManager.lastCompletedSessionID) { _, sessionID in
            guard let sessionID else { return }
            selectedPanel = .meetings
            selectedSessionID = sessionID
        }
        .onChange(of: sessionManager.requestedHomePanel) { _, panel in
            guard let panel else { return }
            selectedPanel = panel
            sessionManager.requestedHomePanel = nil
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

    @ViewBuilder
    private var sidebarContent: some View {
        switch selectedPanel {
        case .meetings:
            MeetingsSidebarView(
                sessionManager: sessionManager,
                sessions: activeSessions,
                searchText: $sidebarSearchText,
                selectedSessionID: $selectedSessionID,
                sessionPendingDelete: $sessionPendingDelete
            )
        case .archived:
            ArchivedMeetingsView(
                sessions: archivedSessions,
                searchText: $sidebarSearchText,
                selectedSessionID: $selectedSessionID,
                sessionPendingDelete: $sessionPendingDelete
            )
        case .settings:
            settingsSidebarPlaceholder
        }
    }

    private var settingsSidebarPlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.6)
                .padding(.horizontal, 12)
                .padding(.top, 16)

            Spacer()
        }
        .frame(width: AppTheme.sidebarWidth)
        .appPanelBackground(AppTheme.bgSidebar)
    }

    @ViewBuilder
    private var detailContent: some View {
        if selectedPanel == .settings {
            SettingsView(sessionManager: sessionManager)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .appPanelBackground(AppTheme.bgPrimary)
        } else if let selectedSession {
            SessionDetailView(
                session: selectedSession,
                onArchive: selectedSession.isArchivedValue ? nil : {
                    archiveSession(selectedSession)
                },
                onUnarchive: selectedSession.isArchivedValue ? {
                    unarchiveSession(selectedSession)
                } : nil,
                onExport: {
                    MeetingMarkdownExporter.export(selectedSession)
                },
                onDelete: {
                    sessionPendingDelete = selectedSession
                }
            )
        } else {
            EmptyDetailView()
        }
    }

    private func validateSelection() {
        guard let selectedSessionID else { return }
        if !allSessions.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = nil
        }
    }

    private func archiveSession(_ session: MeetingSession) {
        SessionActions.archive(session, context: modelContext)
        if selectedSessionID == session.id {
            selectedSessionID = nil
        }
    }

    private func unarchiveSession(_ session: MeetingSession) {
        SessionActions.unarchive(session, context: modelContext)
        if selectedSessionID == session.id {
            selectedSessionID = nil
        }
    }

    private func deletePendingSession() {
        guard let sessionPendingDelete else { return }
        if selectedSessionID == sessionPendingDelete.id {
            selectedSessionID = nil
        }
        SessionActions.delete(sessionPendingDelete, context: modelContext)
        self.sessionPendingDelete = nil
    }
}

#Preview {
    HomeShellView(sessionManager: SessionManager())
        .frame(width: 1100, height: 720)
        .preferredColorScheme(.dark)
        .modelContainer(for: [MeetingSession.self, TranscriptSegment.self, MeetingSummary.self, ActionItem.self], inMemory: true)
}
