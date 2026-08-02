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
                meetingStatusIndicator(label: "Recording", color: AppTheme.danger)

                Button {
                    Task { await sessionManager.pauseMeeting() }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .font(.appBody.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.textPrimary)
                .background(AppTheme.bgInput)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 1)
                }

                stopMeetingButton
                meetingActions

            case .paused:
                meetingStatusIndicator(label: "Paused", color: .yellow)

                Button {
                    Task { await sessionManager.resumeMeeting() }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .font(.appBody.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(AppTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                stopMeetingButton
                meetingActions

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

    private func meetingStatusIndicator(label: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.appCaption.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(MeetingTimeFormatting.elapsed(sessionManager.sessionElapsedTime))
                    .font(.appCaption.monospacedDigit())
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    private var stopMeetingButton: some View {
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
    }

    @ViewBuilder
    private var meetingActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !sessionManager.isSystemAudioEnabled, sessionManager.state == .recording {
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
                },
                help: "Toggle overlay (⌘\\)."
            )

            if sessionManager.isOverlayVisible {
                switch sessionManager.overlayPresentation {
                case .folded:
                    compactButton(
                        title: "Expand Overlay",
                        icon: "rectangle.expand.vertical",
                        action: {
                            sessionManager.expandOverlay()
                        }
                    )
                case .expanded:
                    compactButton(
                        title: "Fold Overlay",
                        icon: "rectangle.compress.vertical",
                        action: {
                            sessionManager.foldOverlay()
                        }
                    )
                case .hidden:
                    EmptyView()
                }
            }
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
