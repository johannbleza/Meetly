import SwiftUI

struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(AppTheme.textSecondary)
            Text("Select a meeting")
                .font(.appBody)
                .foregroundStyle(AppTheme.textPrimary)
            Text("Choose a past meeting to review its transcript and summary.")
                .font(.appCaption)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appPanelBackground(AppTheme.bgPrimary)
    }
}

#Preview {
    EmptyDetailView()
        .frame(width: 600, height: 400)
        .preferredColorScheme(.dark)
}
