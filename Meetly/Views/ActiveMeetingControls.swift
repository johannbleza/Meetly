import SwiftUI

/// The meeting control in the main window's title bar: Start Meeting when idle, or the
/// recording status with Stop (and Resume while paused).
struct ActiveMeetingControls: View {
    @Bindable var sessionManager: SessionManager

    var body: some View {
        HStack(spacing: 8) {
            switch sessionManager.state {
            case .idle:
                TitleBarPill(title: "Start Meeting", systemImage: "mic.fill", style: .accent) {
                    Task { await sessionManager.startMeeting() }
                }

            case .recording:
                status(label: "Recording", color: AppTheme.danger)
                TitleBarPill(title: "Stop", systemImage: "stop.fill", style: .danger) {
                    Task { await sessionManager.stopMeeting() }
                }

            case .paused:
                status(label: "Paused", color: AppTheme.warning)
                TitleBarPill(title: "Resume", systemImage: "play.fill", style: .accent) {
                    Task { await sessionManager.resumeMeeting() }
                }
                TitleBarPill(title: "Stop", systemImage: "stop.fill", style: .danger) {
                    Task { await sessionManager.stopMeeting() }
                }

            case .summarizing:
                SummarizingPill {
                    sessionManager.stopSummarizing()
                }
            }
        }
        .fixedSize()
    }

    private func status(label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.textPrimary)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(MeetingTimeFormatting.elapsed(sessionManager.sessionElapsedTime))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Summarizing…" with a spinner; hovering turns it into a Stop button that ends the summary.
private struct SummarizingPill: View {
    let onStop: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onStop) {
            HStack(spacing: 6) {
                if isHovered {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .semibold))
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(isHovered ? "Stop Summarizing" : "Summarizing…")
                    .font(.system(size: 12, weight: isHovered ? .semibold : .medium))
            }
            .foregroundStyle(isHovered ? AppTheme.danger : AppTheme.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? AppTheme.danger.opacity(0.14) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Stop summarizing this meeting")
        .accessibilityLabel("Stop summarizing")
    }
}

/// A rounded, tinted button sized for the title bar.
struct TitleBarPill: View {
    enum Style { case accent, danger }

    let title: String
    let systemImage: String
    let style: Style
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(background.opacity(isHovered ? 0.8 : 1))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        switch style {
        case .accent: AppTheme.accent
        case .danger: AppTheme.danger
        }
    }

    private var background: Color {
        switch style {
        case .accent: AppTheme.accentSoft
        case .danger: AppTheme.danger.opacity(0.14)
        }
    }
}

#Preview {
    ActiveMeetingControls(sessionManager: SessionManager())
        .padding()
}
