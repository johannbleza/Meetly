import AppKit
import SwiftData
import SwiftUI

struct MenuBarContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
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
            Label {
                Text("Record")
            } icon: {
                Image(nsImage: MeetsSymbol.menuBarImage())
            }
        }

        Button {
            sessionManager.toggleOverlay()
        } label: {
            Label(overlayToggleTitle, systemImage: sessionManager.isOverlayVisible ? "eye.slash" : "eye")
        }

        Divider()

        windowToggleItem

        Button {
            SettingsWindow.open(with: openWindow)
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
            if sessionManager.overlayDock == .notch {
                Button {
                    sessionManager.popOutOverlay()
                } label: {
                    Label("Pop Out Overlay", systemImage: "pip.exit")
                }
            } else {
                Button {
                    sessionManager.dockOverlay()
                } label: {
                    Label("Dock Overlay in Notch", systemImage: "pip.enter")
                }
                switch sessionManager.overlayPresentation {
                case .folded:
                    Button {
                        sessionManager.expandOverlay()
                    } label: {
                        Label("Expand Overlay", systemImage: "chevron.down")
                    }
                case .expanded:
                    Button {
                        sessionManager.foldOverlay()
                    } label: {
                        Label("Fold Overlay", systemImage: "chevron.up")
                    }
                case .hidden:
                    EmptyView()
                }
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
            quickActionButton("Assist", icon: "text.bubble") {
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
            SettingsWindow.open(with: openWindow)
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
            sessionManager.stopSummarizing()
        } label: {
            Label("Stop Summarizing", systemImage: "stop.fill")
        }

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
            Label("Quit Meets", systemImage: "power")
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

/// The Meets symbol, from the `MeetsSymbol` asset (`design/brand/meets-symbol-small.svg`, cropped to the ink).
enum MeetsSymbol {
    static let assetName = "MeetsSymbol"

    /// Sized for the menu bar, as a template image so macOS colors it like other menu bar icons.
    /// The width follows the asset's shape, so a redrawn symbol isn't squashed.
    @MainActor
    static func menuBarImage() -> NSImage {
        guard let source = NSImage(named: assetName), source.size.height > 0 else { return NSImage() }
        let height: CGFloat = 10.75
        let width = (height * source.size.width / source.size.height).rounded()
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Meets"
        return image
    }
}

/// Always the plain symbol: the notch already shows when a meeting is recording or paused.
struct MenuBarIconLabel: View {
    var sessionManager: SessionManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MeetsSymbol.menuBarImage())
            .task {
                // With no main window (after a login launch), showing it has to make one.
                MainWindowController.shared.openWindow = { [openWindow] in
                    openWindow(id: MainWindowController.windowID)
                }
            }
    }
}
