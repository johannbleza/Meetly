import SwiftData
import SwiftUI

struct MeetingsSidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var sessionManager: SessionManager
    let sessions: [MeetingSession]
    @Binding var searchText: String
    @Binding var selectedSessionID: UUID?
    @Binding var sessionPendingDelete: MeetingSession?

    private var filteredSessions: [MeetingSession] {
        sessions.filter { $0.matchesSearch(searchText) }
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
                LazyVStack(spacing: 0) {
                    if filteredSessions.isEmpty {
                        emptyListState
                    } else {
                        ForEach(filteredSessions) { session in
                            SessionListRowView(
                                session: session,
                                isSelected: selectedSessionID == session.id,
                                onSelect: {
                                    selectedSessionID = session.id
                                },
                                onArchive: {
                                    archiveSession(session)
                                },
                                onUnarchive: nil,
                                onExport: {
                                    MeetingMarkdownExporter.export(session)
                                },
                                onDelete: {
                                    sessionPendingDelete = session
                                }
                            )
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .frame(width: AppTheme.sidebarWidth)
        .appPanelBackground(AppTheme.bgSidebar)
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meetings")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.6)

            ActiveMeetingControls(sessionManager: sessionManager)

            AppSearchField(text: $searchText, placeholder: "Search meetings")
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
            Text(searchText.isEmpty ? "No meetings yet" : "No matches")
                .font(.appBody)
                .foregroundStyle(AppTheme.textPrimary)
            Text(
                searchText.isEmpty
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
        searchText: .constant(""),
        selectedSessionID: .constant(nil),
        sessionPendingDelete: .constant(nil)
    )
    .frame(height: 500)
    .preferredColorScheme(.dark)
    .modelContainer(for: [MeetingSession.self, TranscriptSegment.self, MeetingSummary.self, ActionItem.self], inMemory: true)
}
