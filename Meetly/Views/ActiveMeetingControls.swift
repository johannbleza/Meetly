import SwiftUI

struct ActiveMeetingControls: View {
    @Bindable var sessionManager: SessionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch sessionManager.state {
            case .idle:
                Button {
                    Task { await sessionManager.startMeeting() }
                } label: {
                    Label("Start Meeting", systemImage: "mic.fill")
                        .font(.appBody.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(AppTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            case .recording:
                HStack(spacing: 8) {
                    Circle()
                        .fill(AppTheme.danger)
                        .frame(width: 8, height: 8)
                    Text("Recording")
                        .font(.appCaption.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                }

                Button {
                    Task { await sessionManager.stopMeeting() }
                } label: {
                    Label("Stop Meeting", systemImage: "stop.fill")
                        .font(.appBody.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(AppTheme.danger)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                recordingActions

            case .summarizing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating summary...")
                        .font(.appCaption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var recordingActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !sessionManager.isSystemAudioEnabled {
                compactButton(
                    title: "Capture Meeting Audio",
                    icon: "speaker.wave.2.fill",
                    action: {
                        Task { await sessionManager.enableSystemAudio() }
                    },
                    help: "Optional. macOS requires Screen & System Audio Recording to hear other participants."
                )
            }

            compactButton(
                title: sessionManager.isOverlayVisible ? "Hide Overlay" : "Show Overlay",
                icon: sessionManager.isOverlayVisible ? "eye.slash" : "eye",
                action: {
                    sessionManager.toggleOverlay()
                }
            )
        }
    }

    private func compactButton(
        title: String,
        icon: String,
        action: @escaping () -> Void,
        help: String? = nil
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.appCaption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.textPrimary)
        .background(AppTheme.bgInput)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        }
        .help(help ?? title)
    }
}

#Preview {
    ActiveMeetingControls(sessionManager: SessionManager())
        .padding()
        .frame(width: 260)
        .appPanelBackground(AppTheme.bgSidebar)
        .preferredColorScheme(.dark)
}
