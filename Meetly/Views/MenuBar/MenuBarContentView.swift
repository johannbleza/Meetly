import AppKit
import SwiftData
import SwiftUI

struct MenuBarContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var sessionManager: SessionManager

    var body: some View {
        Group {
            switch sessionManager.state {
            case .idle:
                idleMenu
            case .recording, .paused:
                activeMeetingMenu
            case .summarizing:
                summarizingMenu
            }
        }
        .onAppear {
            sessionManager.configure(modelContext: modelContext)
            OverlayPanelController.shared.configure(sessionManager: sessionManager)
            OverlayKeyboardShortcutController.shared.configure(sessionManager: sessionManager)
        }
    }

    @ViewBuilder
    private var idleMenu: some View {
        Button {
            Task { await sessionManager.startMeeting() }
        } label: {
            Label("Start Meeting", systemImage: "mic.fill")
        }

        Button {
            sessionManager.toggleOverlay()
        } label: {
            Label(overlayToggleTitle, systemImage: sessionManager.isOverlayVisible ? "eye.slash" : "eye")
        }

        Divider()

        windowToggleItem

        Button {
            sessionManager.openSettings()
        } label: {
            Label("Settings…", systemImage: "gearshape")
        }

        Divider()

        quitButton
    }

    @ViewBuilder
    private var activeMeetingMenu: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Label {
                Text("\(sessionManager.state == .paused ? "Paused" : "Recording") • \(MeetingTimeFormatting.elapsed(sessionManager.sessionElapsedTime))")
            } icon: {
                Image(systemName: sessionManager.state == .paused ? "pause.circle.fill" : "record.circle.fill")
                    .foregroundStyle(sessionManager.state == .paused ? .yellow : .red)
            }
        }
        .disabled(true)

        if sessionManager.state == .recording {
            Button {
                Task { await sessionManager.pauseMeeting() }
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
        } else {
            Button {
                Task { await sessionManager.resumeMeeting() }
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
        }

        Button {
            Task { await sessionManager.stopMeeting() }
        } label: {
            Label("Stop Meeting", systemImage: "stop.fill")
        }

        Button {
            sessionManager.toggleOverlay()
        } label: {
            Label(
                overlayToggleTitle,
                systemImage: sessionManager.isOverlayVisible ? "eye.slash" : "eye"
            )
        }

        if sessionManager.isOverlayVisible {
            switch sessionManager.overlayPresentation {
            case .folded:
                Button {
                    sessionManager.expandOverlay()
                } label: {
                    Label("Expand Overlay", systemImage: "rectangle.expand.vertical")
                }
            case .expanded:
                Button {
                    sessionManager.foldOverlay()
                } label: {
                    Label("Fold Overlay", systemImage: "rectangle.compress.vertical")
                }
            case .hidden:
                EmptyView()
            }
        }

        if !sessionManager.isSystemAudioEnabled, sessionManager.state == .recording {
            Button {
                Task { await sessionManager.enableSystemAudio() }
            } label: {
                Label("Capture Meeting Audio", systemImage: "speaker.wave.2.fill")
            }
        }

        Divider()

        Menu("Quick Actions") {
            quickActionButton("Assist", icon: "sparkles") {
                "How can I assist in this meeting right now?"
            }
            quickActionButton("What to say", icon: "text.quote") {
                "What should I say next based on this conversation?"
            }
            quickActionButton("Follow-ups", icon: "bubble.left") {
                "Suggest 2-3 good follow-up questions I could ask."
            }
            quickActionButton("Recap", icon: "arrow.clockwise") {
                "Give me a brief recap of what's been discussed so far."
            }
        }

        Divider()

        Button {
            MainWindowController.shared.showMainWindow()
        } label: {
            Label("Show Main Window", systemImage: "macwindow")
        }

        Button {
            sessionManager.openSettings()
        } label: {
            Label("Settings…", systemImage: "gearshape")
        }

        Divider()

        quitButton
    }

    @ViewBuilder
    private var summarizingMenu: some View {
        Text("Generating summary…")
            .disabled(true)

        Button {
            MainWindowController.shared.showMainWindow()
        } label: {
            Label("Show Main Window", systemImage: "macwindow")
        }

        Divider()

        quitButton
    }

    @ViewBuilder
    private var windowToggleItem: some View {
        if MainWindowController.shared.isMainWindowVisible {
            Button {
                MainWindowController.shared.hideMainWindow()
            } label: {
                Label("Hide Window", systemImage: "macwindow.on.rectangle")
            }
        } else {
            Button {
                MainWindowController.shared.showMainWindow()
            } label: {
                Label("Show Window", systemImage: "macwindow")
            }
        }
    }

    private var overlayToggleTitle: String {
        let action = sessionManager.isOverlayVisible ? "Hide Overlay" : "Show Overlay"
        return "\(action)\t⌘\\"
    }

    private var quitButton: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("Quit Meetly", systemImage: "power")
        }
    }

    private func quickActionButton(
        _ title: String,
        icon: String,
        prompt: @escaping () -> String
    ) -> some View {
        Button {
            Task { await sessionManager.askQuestion(prompt()) }
        } label: {
            Label(title, systemImage: icon)
        }
        .disabled(sessionManager.isAwaitingAnswer)
    }
}

enum MenuBarIcon {
    static func systemImage(for state: MeetingState) -> String {
        switch state {
        case .idle:
            "waveform.circle"
        case .recording:
            "record.circle.fill"
        case .paused:
            "pause.circle.fill"
        case .summarizing:
            "sparkles"
        }
    }
}

struct MenuBarIconLabel: View {
    var sessionManager: SessionManager

    var body: some View {
        Image(systemName: MenuBarIcon.systemImage(for: sessionManager.state))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(iconColor)
            .symbolEffect(.pulse, options: .repeating, isActive: sessionManager.state == .recording)
    }

    private var iconColor: Color {
        switch sessionManager.state {
        case .recording:
            .red
        case .paused:
            .yellow
        case .summarizing:
            .secondary
        default:
            .primary
        }
    }
}
