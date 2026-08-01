import AppKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var sessionManager: SessionManager

    var body: some View {
        HomeShellView(sessionManager: sessionManager)
            .background(MainWindowReader())
            .onAppear {
                sessionManager.configure(modelContext: modelContext)
                OverlayPanelController.shared.configure(sessionManager: sessionManager)
            }
    }
}

private struct MainWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                MainWindowController.shared.register(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                MainWindowController.shared.register(window)
            }
        }
    }
}

#Preview {
    ContentView(sessionManager: SessionManager())
        .modelContainer(for: [MeetingSession.self, TranscriptSegment.self, MeetingSummary.self], inMemory: true)
        .preferredColorScheme(.dark)
}
