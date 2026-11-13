import SwiftUI

enum MeetingTimeFormatting {
    static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

/// One-click questions offered in both the floating overlay and the notch.
enum OverlayQuickPrompt {
    static let whatToSay = "What should I say next based on this conversation?"
    static let recap = "Give me a brief recap of what's been discussed so far."
    static let screen =
        "This is a screenshot of my screen right now. Explain what it shows and point out anything useful for this meeting."
}

struct OverlayToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(.separator.opacity(0.5))
            .frame(width: 1, height: 16)
    }
}

struct OverlayToolbarIconButton: View {
    let systemImage: String
    let help: String
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(tint)
        .help(help)
    }
}

/// Shared chrome for folded + expanded meeting overlays so icons stay anchored.
struct OverlayMeetingToolbar: View {
    @Bindable var sessionManager: SessionManager
    @Binding var isShowingSettings: Bool
    var isFolded: Bool

    var body: some View {
        // Same layout as the notch's top bar: status on the left, controls on the right.
        HStack(spacing: 10) {
            OverlayStatusIndicator(sessionManager: sessionManager, showsLabel: true)

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                OverlayToolbarIconButton(systemImage: "stop.fill", help: "Stop meeting", tint: .red) {
                    Task { await sessionManager.stopMeeting() }
                }
                OverlaySettingsButton(sessionManager: sessionManager, isShowingSettings: $isShowingSettings)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            OverlayWindowDragRegion()
        }
    }
}

struct OverlayStatusIndicator: View {
    var sessionManager: SessionManager
    var showsLabel = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(MeetingTimeFormatting.elapsed(sessionManager.sessionElapsedTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if showsLabel {
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch sessionManager.state {
        case .recording:
            .red
        case .paused:
            .yellow
        default:
            .secondary
        }
    }

    private var statusLabel: String {
        switch sessionManager.state {
        case .recording:
            "Recording"
        case .paused:
            "Paused"
        default:
            ""
        }
    }
}

struct OverlaySettingsButton: View {
    @Bindable var sessionManager: SessionManager
    @Binding var isShowingSettings: Bool

    var body: some View {
        OverlayToolbarIconButton(systemImage: "gearshape", help: "Settings") {
            isShowingSettings.toggle()
        }
        .popover(isPresented: $isShowingSettings, arrowEdge: .bottom) {
            OverlaySettingsView(sessionManager: sessionManager)
        }
    }
}
