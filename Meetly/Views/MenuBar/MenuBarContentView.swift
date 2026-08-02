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
            case .recording:
                recordingMenu
            case .summarizing:
                summarizingMenu
            }
        }
        .onAppear {
            sessionManager.configure(modelContext: modelContext)
            OverlayPanelController.shared.configure(sessionManager: sessionManager)
        }
    }

    @ViewBuilder
    private var idleMenu: some View {
        Button {
            Task { await sessionManager.startMeeting() }
        } label: {
            Label("Start Meeting", systemImage: "mic.fill")
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
    private var recordingMenu: some View {
        if let startedAt = sessionManager.sessionStartedAt {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text("Recording • \(elapsed(since: startedAt))")
            }
            .disabled(true)
        } else {
            Text("Recording")
                .disabled(true)
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
                sessionManager.isOverlayVisible ? "Hide Overlay" : "Show Overlay",
                systemImage: sessionManager.isOverlayVisible ? "eye.slash" : "eye"
            )
        }

        if !sessionManager.isSystemAudioEnabled {
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

    private func elapsed(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

enum MenuBarIcon {
    static func systemImage(for state: MeetingState) -> String {
        switch state {
        case .idle, .summarizing:
            "waveform.circle"
        case .recording:
            "mic.fill"
        }
    }
}

struct MenuBarIconLabel: View {
    var sessionManager: SessionManager

    var body: some View {
        Image(systemName: MenuBarIcon.systemImage(for: sessionManager.state))
            .symbolRenderingMode(sessionManager.state == .recording ? .multicolor : .monochrome)
            .foregroundStyle(sessionManager.state == .recording ? .red : .primary)
    }
}
