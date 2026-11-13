import SwiftData
import SwiftUI

struct MeetingsSidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var sessionManager: SessionManager
    let sessions: [MeetingSession]
    /// Owned here so typing only redraws the sidebar, not the open meeting.
    @State private var search = SidebarSearchModel()
    @Binding var selectedSessionID: UUID?
    @Binding var sessionPendingDelete: MeetingSession?

    /// Pinned meetings (most recently pinned on top) and the rest (newest first).
    private var filteredGroups: (pinned: [MeetingSession], unpinned: [MeetingSession]) {
        let matches = search.isSearching ? sessions.filter(search.matches) : sessions
        let pinned = matches
            .filter(\.isPinned)
            .sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
        return (pinned, matches.filter { !$0.isPinned })
    }

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader

            if let errorMessage = sessionManager.errorMessage {
                statusBanner(errorMessage, color: AppTheme.danger)
            }

            if let warningMessage = sessionManager.warningMessage {
                statusBanner(warningMessage, color: AppTheme.warning)
            }

            if !sessionManager.isAIAvailable {
                statusBanner(
                    sessionManager.aiAvailabilityMessage
                        ?? "Configure \(sessionManager.aiProvider.label) in Settings for AI answers and summaries.",
                    color: AppTheme.textSecondary
                )
            }

            ScrollView {
                let groups = filteredGroups
                LazyVStack(spacing: 0) {
                    if groups.pinned.isEmpty && groups.unpinned.isEmpty {
                        emptyListState
                    } else {
                        ForEach(groups.pinned) { session in
                            sessionRow(session)
                        }

                        if !groups.pinned.isEmpty && !groups.unpinned.isEmpty {
                            AppDivider(axis: .horizontal)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }

                        ForEach(groups.unpinned) { session in
                            sessionRow(session)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appPanelBackground(AppTheme.bgSidebar)
        .onAppear {
            search.attach(to: modelContext.container)
        }
        .onChange(of: sessions.count) { _, _ in
            search.meetingsChanged()
        }
    }

    private func sessionRow(_ session: MeetingSession) -> some View {
        let isInUse = sessionManager.isInUse(session)
        return SessionListRowView(
            session: session,
            isSelected: selectedSessionID == session.id,
            onSelect: {
                selectedSessionID = session.id
            },
            onContinue: sessionManager.state == .idle ? {
                selectedSessionID = session.id
                Task { await sessionManager.continueMeeting(session) }
            } : nil,
            onTogglePin: {
                SessionActions.togglePin(session, context: modelContext)
            },
            onArchive: isInUse ? nil : {
                archiveSession(session)
            },
            onUnarchive: nil,
            onExport: {
                MeetingMarkdownExporter.export(session)
            },
            onDelete: isInUse ? nil : {
                sessionPendingDelete = session
            }
        )
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meetings")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.6)

            ActiveMeetingControls(sessionManager: sessionManager)

            AppSearchField(text: $search.text, placeholder: "Search meetings")
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var emptyListState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(AppTheme.textSecondary)
            Text(search.text.isEmpty ? "No meetings yet" : "No matches")
                .font(.appBody)
                .foregroundStyle(AppTheme.textPrimary)
            Text(
                search.text.isEmpty
                    ? "Start a meeting to capture transcripts and summaries."
                    : "Try a different search term."
            )
            .font(.appCaption)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 32)
    }

    private func statusBanner(_ message: String, color: Color) -> some View {
        Text(message)
            .font(.appCaption)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AppTheme.bgInput.opacity(0.65))
    }

    private func archiveSession(_ session: MeetingSession) {
        guard !sessionManager.isInUse(session) else { return }
        SessionActions.archive(session, context: modelContext)
        if selectedSessionID == session.id {
            selectedSessionID = nil
        }
    }
}

#Preview {
    MeetingsSidebarView(
        sessionManager: SessionManager(),
        sessions: [MeetingSession(title: "Weekly Sync")],
        selectedSessionID: .constant(nil),
        sessionPendingDelete: .constant(nil)
    )
    .frame(height: 500)
    .preferredColorScheme(.dark)
    .modelContainer(for: [MeetingSession.self, TranscriptSegment.self, MeetingSummary.self, ActionItem.self], inMemory: true)
}
