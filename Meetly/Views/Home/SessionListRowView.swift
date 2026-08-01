import SwiftUI

struct SessionListRowView: View {
    let session: MeetingSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onArchive: (() -> Void)?
    let onUnarchive: (() -> Void)?
    let onExport: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .font(.appBody)
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)

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
            Divider()
            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
    }

    @ViewBuilder
    private var rowActions: some View {
        HStack(spacing: 2) {
            rowActionButton(icon: "square.and.arrow.up", help: "Export as Markdown") {
                onExport()
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
            rowActionButton(icon: "trash", help: "Delete", tint: AppTheme.danger) {
                onDelete()
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
        onArchive: {},
        onUnarchive: nil,
        onExport: {},
        onDelete: {}
    )
    .frame(width: 260)
    .preferredColorScheme(.dark)
}
