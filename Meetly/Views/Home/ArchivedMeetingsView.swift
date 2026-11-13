import SwiftData
import SwiftUI

struct ArchivedMeetingsView: View {
    @Environment(\.modelContext) private var modelContext
    let sessions: [MeetingSession]
    /// The meeting being recorded or summarized, which can't be deleted yet.
    var inUseSessionID: UUID? = nil
    /// Owned here so typing only redraws the sidebar, not the open meeting.
    @State private var search = SidebarSearchModel()
    @Binding var selectedSessionID: UUID?
    @Binding var sessionPendingDelete: MeetingSession?
    @State private var showDeleteAllConfirmation = false

    private var filteredSessions: [MeetingSession] {
        search.isSearching ? sessions.filter(search.matches) : sessions
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

                AppSearchField(text: $search.text, placeholder: "Search archived")
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
                                onContinue: nil,
                                onArchive: nil,
                                onUnarchive: {
                                    unarchiveSession(session)
                                },
                                onExport: {
                                    MeetingMarkdownExporter.export(session)
                                },
                                onDelete: session.id == inUseSessionID ? nil : {
                                    sessionPendingDelete = session
                                }
                            )
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
            Text(search.text.isEmpty ? "No archived meetings" : "No matches")
                .font(.appBody)
                .foregroundStyle(AppTheme.textPrimary)
            Text(
                search.text.isEmpty
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
        let deletable = filteredSessions.filter { $0.id != inUseSessionID }
        SessionActions.deleteAllArchived(deletable, context: modelContext)
        if let selectedSessionID,
           deletable.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = nil
        }
    }
}

#Preview {
    ArchivedMeetingsView(
        sessions: [MeetingSession(title: "Old Sync", isArchived: true, archivedAt: .now)],
        selectedSessionID: .constant(nil),
        sessionPendingDelete: .constant(nil)
    )
    .frame(height: 500)
    .preferredColorScheme(.dark)
    .modelContainer(for: [MeetingSession.self, TranscriptSegment.self, MeetingSummary.self, ActionItem.self], inMemory: true)
}
