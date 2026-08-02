import SwiftUI

struct OverlayFoldedBar: View {
    @Bindable var sessionManager: SessionManager
    @State private var isShowingSettings = false

    var body: some View {
        HStack(spacing: 10) {
            OverlayStatusIndicator(sessionManager: sessionManager, showsLabel: true)

            Spacer(minLength: 0)

            OverlayToolbarDivider()

            HStack(spacing: 4) {
                OverlayPauseResumeButton(sessionManager: sessionManager)
                OverlayToolbarIconButton(systemImage: "stop.fill", help: "Stop meeting", tint: .red) {
                    Task { await sessionManager.stopMeeting() }
                }
                OverlayToolbarIconButton(systemImage: "rectangle.expand.vertical", help: "Expand overlay") {
                    sessionManager.expandOverlay()
                }
                OverlayToolbarIconButton(systemImage: "eye.slash", help: "Hide overlay") {
                    sessionManager.hideOverlay()
                }
                OverlaySettingsButton(sessionManager: sessionManager, isShowingSettings: $isShowingSettings)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: OverlayGlassStyle.panelWidth, height: OverlayGlassStyle.panelFoldedHeight)
        .overlayGlassPanel()
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }
}
