import SwiftData
import SwiftUI

struct ArchivedMeetingsView: View {
    @Environment(\.modelContext) private var modelContext
    let sessions: [MeetingSession]
    @Binding var searchText: String
    @Binding var selectedSessionID: UUID?
    @Binding var sessionPendingDelete: MeetingSession?
    @State private var showDeleteAllConfirmation = false

    private var filteredSessions: [MeetingSession] {
        sessions.filter { $0.matchesSearch(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Archived")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .textCase(.uppercase)
                        .tracking(0.6)

                    Spacer()

                    if !filteredSessions.isEmpty {
                        Button("Delete All") {
                            showDeleteAllConfirmation = true
                        }
                        .buttonStyle(.plain)
                        .font(.appCaption)
                        .foregroundStyle(AppTheme.danger)
                    }
                }

                AppSearchField(text: $searchText, placeholder: "Search archived")
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 12)

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
                                onArchive: nil,
                                onUnarchive: {
                                    unarchiveSession(session)
                                },
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
        .alert("Delete all archived meetings?", isPresented: $showDeleteAllConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                deleteAllArchived()
            }
        } message: {
            Text("This permanently removes every archived meeting and cannot be undone.")
        }
    }

    private var emptyListState: some View {
        VStack(spacing: 8) {
            Image(systemName: "archivebox")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(AppTheme.textSecondary)
            Text(searchText.isEmpty ? "No archived meetings" : "No matches")
                .font(.appBody)
                .foregroundStyle(AppTheme.textPrimary)
            Text(
                searchText.isEmpty
                    ? "Archived meetings will appear here."
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

    private func unarchiveSession(_ session: MeetingSession) {
        SessionActions.unarchive(session, context: modelContext)
        if selectedSessionID == session.id {
            selectedSessionID = nil
        }
    }

    private func deleteAllArchived() {
        SessionActions.deleteAllArchived(filteredSessions, context: modelContext)
        if let selectedSessionID,
           filteredSessions.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = nil
        }
    }
}

#Preview {
    ArchivedMeetingsView(
        sessions: [MeetingSession(title: "Old Sync", isArchived: true, archivedAt: .now)],
        searchText: .constant(""),
        selectedSessionID: .constant(nil),
        sessionPendingDelete: .constant(nil)
    )
    .frame(height: 500)
    .preferredColorScheme(.dark)
    .modelContainer(for: [MeetingSession.self, TranscriptSegment.self, MeetingSummary.self], inMemory: true)
}
