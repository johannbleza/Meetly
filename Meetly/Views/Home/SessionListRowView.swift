import SwiftUI

struct SessionListRowView: View {
    let session: MeetingSession
    let isSelected: Bool
    let onSelect: () -> Void
    /// Nil while a meeting is recording, or where continuing doesn't apply.
    let onContinue: (() -> Void)?
    /// Nil where pinning doesn't apply (archived meetings).
    var onTogglePin: (() -> Void)? = nil
    let onArchive: (() -> Void)?
    let onUnarchive: (() -> Void)?
    let onExport: () -> Void
    /// Nil while the meeting is being recorded.
    let onDelete: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .accessibilityLabel("Pinned")
                    }
                    Text(session.displayTitle)
                        .font(.appBody)
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    if let duration = session.formattedDuration() {
                        Text("·")
                        Text(duration)
                    }
                }
                .font(.appCaption)
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isHovered {
                rowActions
            }
        }
        .appListRow(selected: isSelected, hovered: isHovered && !isSelected)
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            if let onContinue {
                Button("Continue Meeting") {
                    onContinue()
                }
                Divider()
            }
            if let onTogglePin {
                Button(session.isPinned ? "Unpin" : "Pin") {
                    onTogglePin()
                }
            }
            Button("Export as Markdown") {
                onExport()
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
        }
    }

    @ViewBuilder
    private var rowActions: some View {
        HStack(spacing: 2) {
            if let onContinue {
                rowActionButton(icon: "play.fill", help: "Continue Meeting") {
                    onContinue()
                }
            }
            if let onTogglePin {
                rowActionButton(
                    icon: session.isPinned ? "pin.slash" : "pin",
                    help: session.isPinned ? "Unpin" : "Pin"
                ) {
                    onTogglePin()
                }
            }
            if let onUnarchive {
                rowActionButton(icon: "arrow.uturn.backward", help: "Unarchive") {
                    onUnarchive()
                }
            }
            if let onArchive {
                rowActionButton(icon: "archivebox", help: "Archive") {
                    onArchive()
                }
            }
            if let onDelete {
                rowActionButton(icon: "trash", help: "Delete", tint: AppTheme.danger) {
                    onDelete()
                }
            }
        }
    }

    private func rowActionButton(
        icon: String,
        help: String,
        tint: Color = AppTheme.textSecondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(AppTheme.bgInput)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

#Preview {
    let session = MeetingSession(title: "Weekly Sync")
    return SessionListRowView(
        session: session,
        isSelected: true,
        onSelect: {},
        onContinue: {},
        onArchive: {},
        onUnarchive: nil,
        onExport: {},
        onDelete: {}
    )
    .frame(width: 260)
    .preferredColorScheme(.dark)
}
