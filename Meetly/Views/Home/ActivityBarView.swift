import SwiftUI

struct ActivityBarView: View {
    @Binding var selectedPanel: HomePanel

    var body: some View {
        VStack(spacing: 4) {
            activityButton(
                panel: .meetings,
                icon: "calendar",
                label: "Meetings"
            )
            activityButton(
                panel: .archived,
                icon: "archivebox",
                label: "Archived"
            )

            Spacer()

            activityButton(
                panel: .settings,
                icon: "gearshape",
                label: "Settings"
            )
        }
        .padding(.vertical, 12)
        .frame(width: AppTheme.activityBarWidth)
        .appPanelBackground(AppTheme.bgActivityBar)
    }

    private func activityButton(panel: HomePanel, icon: String, label: String) -> some View {
        Button {
            selectedPanel = panel
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(selectedPanel == panel ? AppTheme.textPrimary : AppTheme.textSecondary)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selectedPanel == panel ? AppTheme.bgHover : .clear)
                )
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

#Preview {
    ActivityBarView(selectedPanel: .constant(.meetings))
        .frame(height: 400)
        .preferredColorScheme(.dark)
}
