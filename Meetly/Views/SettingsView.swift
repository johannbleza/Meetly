import AppKit
import ServiceManagement
import SwiftUI

/// Opens the Settings window (⌘, the title-bar gear, or the menu bar).
enum SettingsWindow {
    static let id = "settings"

    @MainActor
    static func open(with openWindow: OpenWindowAction) {
        openWindow(id: id)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/// "Settings…" (⌘,) in the app menu.
struct SettingsMenuCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            SettingsWindow.open(with: openWindow)
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

/// Keeps the Settings window out of screen shares, like Meets's other windows.
struct SettingsWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                ScreenShareExclusion.apply(to: window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private enum SettingsPage: CaseIterable, Hashable {
    case general, transcription, ai, meetings, overlay, shortcuts

    var title: String {
        switch self {
        case .general: "General"
        case .transcription: "Transcription"
        case .ai: "AI"
        case .meetings: "Meetings"
        case .overlay: "Overlay"
        case .shortcuts: "Shortcuts"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .transcription: "waveform"
        case .ai: "sparkles"
        case .meetings: "phone"
        case .overlay: "rectangle.on.rectangle"
        case .shortcuts: "command"
        }
    }
}

struct SettingsView: View {
    @State private var page: SettingsPage = .general
    @State private var transcriptionEngine = AppSettings.transcriptionEngine
    @State private var whisperModel = AppSettings.whisperModel
    @State private var aiProvider = AppSettings.aiProvider
    @State private var claudeModel = AppSettings.claudeModel
    @State private var codexModel = AppSettings.codexModel
    @State private var aiWebSearchEnabled = AppSettings.aiWebSearchEnabled
    @State private var overlayOpacity = AppSettings.overlayOpacity
    @State private var hideFromScreenShare = AppSettings.hideFromScreenShare
    @State private var captureMeetingAudioByDefault = AppSettings.captureMeetingAudioByDefault
    @State private var detectMeetings = AppSettings.detectMeetings
    @State private var autoStopWhenCallEnds = AppSettings.autoStopWhenCallEnds
    @State private var idleRecordingStopMinutes = AppSettings.idleRecordingStopMinutes
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var openAtLoginError: String?
    @State private var statusMessage: String?
    @State private var isTesting = false
    @AppStorage(AppSettings.appThemeKey) private var appTheme: AppTheme.Mode = .system

    var body: some View {
        HStack(spacing: 0) {
            navigation
            AppDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    pageContent
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 32)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AppTheme.bgSidebar)
        }
        .onChange(of: transcriptionEngine) { _, newValue in AppSettings.transcriptionEngine = newValue }
        .onChange(of: whisperModel) { _, newValue in AppSettings.whisperModel = newValue }
        .onChange(of: aiProvider) { _, newValue in
            AppSettings.aiProvider = newValue
            statusMessage = nil
        }
        .onChange(of: claudeModel) { _, newValue in
            AppSettings.claudeModel = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .onChange(of: codexModel) { _, newValue in
            AppSettings.codexModel = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .onChange(of: aiWebSearchEnabled) { _, newValue in AppSettings.aiWebSearchEnabled = newValue }
        .onChange(of: overlayOpacity) { _, newValue in AppSettings.overlayOpacity = newValue }
        .onChange(of: hideFromScreenShare) { _, newValue in
            AppSettings.hideFromScreenShare = newValue
            ScreenShareExclusion.applyToAllWindows()
        }
        .onChange(of: captureMeetingAudioByDefault) { _, newValue in
            AppSettings.captureMeetingAudioByDefault = newValue
        }
        .onChange(of: detectMeetings) { _, newValue in AppSettings.detectMeetings = newValue }
        .onChange(of: autoStopWhenCallEnds) { _, newValue in AppSettings.autoStopWhenCallEnds = newValue }
        .onChange(of: idleRecordingStopMinutes) { _, newValue in AppSettings.idleRecordingStopMinutes = newValue }
    }

    // MARK: Navigation

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPage.allCases, id: \.self) { item in
                SettingsNavItem(title: item.title, systemImage: item.systemImage, isSelected: page == item) {
                    page = item
                }
            }

            Spacer()

            SettingsNavItem(title: "Quit Meets", systemImage: "power", isSelected: false) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .padding(.top, 6)
        .frame(width: 220, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AppTheme.bgPrimary)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .general: generalPage
        case .transcription: transcriptionPage
        case .ai: aiPage
        case .meetings: meetingsPage
        case .overlay: overlayPage
        case .shortcuts: shortcutsPage
        }
    }

    // MARK: General

    @ViewBuilder
    private var generalPage: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    hideFromScreenShare ? "Hidden from screen share" : "Visible in screen share",
                    systemImage: hideFromScreenShare ? "eye.slash" : "eye"
                )
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                Text(hideFromScreenShare
                    ? "Meets's windows don't show up when you share your screen in Zoom, Google Meet and other apps."
                    : "Other people can see Meets's windows when you share your screen.")
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("Hide from screen share", isOn: $hideFromScreenShare)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.bgInput.opacity(0.6)))
        .padding(.bottom, 28)

        SettingsGroupHeader(title: "General settings", subtitle: "How Meets starts and looks")

        SettingsRow(
            systemImage: "power",
            title: "Open Meets at login",
            subtitle: openAtLoginError ?? "Meets starts automatically when you log in, so it can notice calls."
        ) {
            Toggle("Open Meets at login", isOn: Binding(get: { openAtLogin }, set: { setOpenAtLogin($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }

        SettingsRow(
            systemImage: "paintbrush",
            title: "Theme",
            subtitle: "How the main window looks. The overlay and notch always stay dark."
        ) {
            Picker("Theme", selection: $appTheme) {
                ForEach(AppTheme.Mode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }

        SettingsRow(
            systemImage: "checkmark.seal",
            title: "Version",
            subtitle: "You're using Meets \(appVersion)."
        ) {
            EmptyView()
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            openAtLoginError = nil
        } catch {
            openAtLoginError = error.localizedDescription
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Transcription

    @ViewBuilder
    private var transcriptionPage: some View {
        SettingsGroupHeader(title: "Transcription", subtitle: "Changes apply to your next meeting.")

        SettingsRow(systemImage: "waveform", title: "Engine", subtitle: transcriptionEngine.settingsDescription) {
            Picker("Engine", selection: $transcriptionEngine) {
                ForEach(TranscriptionEngine.allCases) { engine in
                    Text(engine.label).tag(engine)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }

        if transcriptionEngine == .whisper {
            SettingsRow(systemImage: "cpu", title: "Whisper model", subtitle: "Larger models are more accurate but slower.") {
                Picker("Model", selection: $whisperModel) {
                    ForEach(WhisperModel.allCases) { model in
                        Text(model.label).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            whisperModelStatus
        }
    }

    @ViewBuilder
    private var whisperModelStatus: some View {
        let store = WhisperModelStore.shared

        if store.installingModel == whisperModel, let phase = store.installPhase {
            switch phase {
            case .downloading(let fraction):
                SettingsRow(systemImage: "arrow.down.circle", title: "Downloading model…", subtitle: nil) {
                    Button("Cancel") { store.cancelInstall() }
                }
                ProgressView(value: fraction)
                    .padding(.leading, 50)
                    .padding(.bottom, 8)
            case .optimizing:
                SettingsRow(
                    systemImage: "gearshape.2",
                    title: "Optimizing for this Mac",
                    subtitle: "This can take a few minutes."
                ) {
                    ProgressView().controlSize(.small)
                }
            }
        } else if store.isInstalled(whisperModel) {
            SettingsRow(
                systemImage: "checkmark.circle",
                iconTint: AppTheme.success,
                title: "Model ready",
                subtitle: "Downloaded and ready for your next meeting."
            ) {
                Button("Remove Download") { store.remove(whisperModel) }
            }
        } else {
            SettingsRow(
                systemImage: "arrow.down.circle",
                iconTint: AppTheme.warning,
                title: "Download this model to use it",
                subtitle: "Until it's ready, meetings use Apple Speech."
            ) {
                Button("Download Model") { store.install(whisperModel) }
                    .disabled(store.installingModel != nil)
            }
        }

        if let error = store.lastError {
            SettingsFootnote(text: error, color: AppTheme.danger)
        }
    }

    // MARK: AI

    @ViewBuilder
    private var aiPage: some View {
        SettingsGroupHeader(title: "AI", subtitle: "Used for live answers, summaries and action items.")

        SettingsRow(systemImage: "sparkles", title: "Provider", subtitle: aiProvider.settingsDescription) {
            Picker("Provider", selection: $aiProvider) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.label).tag(provider)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }

        if let agent = aiProvider.cliAgent {
            SettingsRow(
                systemImage: agent.isInstalled ? "checkmark.circle" : "exclamationmark.triangle",
                iconTint: agent.isInstalled ? AppTheme.success : AppTheme.warning,
                title: "\(agent.label) command-line tool",
                subtitle: agent.isInstalled ? "Found the `\(agent.command)` command-line tool." : agent.setupMessage
            ) {
                EmptyView()
            }

            SettingsRow(
                systemImage: "cube",
                title: "Model",
                subtitle: agent == .claude
                    ? "A model name or alias such as sonnet, opus, or haiku."
                    : "Leave empty to use the default model for your Codex plan."
            ) {
                Group {
                    switch agent {
                    case .claude:
                        TextField("Model", text: $claudeModel)
                    case .codex:
                        TextField("Model", text: $codexModel, prompt: Text("Codex default"))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 170)
            }

            SettingsRow(
                systemImage: "globe",
                title: "Allow web search for questions",
                subtitle: "Lets \(agent.label) search the web when a question needs current facts or knowledge outside the meeting transcript. Summaries stay transcript-only."
            ) {
                Toggle("Allow web search for questions", isOn: $aiWebSearchEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            testConnectionRow(isEnabled: agent.isInstalled)
        } else {
            SettingsRow(
                systemImage: FoundationModelsClient.isAvailable ? "checkmark.circle" : "exclamationmark.triangle",
                iconTint: FoundationModelsClient.isAvailable ? AppTheme.success : AppTheme.warning,
                title: FoundationModelsClient.isAvailable ? "On-device model ready" : "Apple Intelligence unavailable",
                subtitle: FoundationModelsClient.isAvailable
                    ? "AI answers and post-meeting summaries run on-device."
                    : (FoundationModelsClient.availabilityMessage ?? "Apple Intelligence is unavailable.")
            ) {
                EmptyView()
            }

            testConnectionRow(isEnabled: FoundationModelsClient.isAvailable)
        }
    }

    private func testConnectionRow(isEnabled: Bool) -> some View {
        SettingsRow(
            systemImage: "bolt.horizontal",
            title: "Test connection",
            subtitle: statusMessage ?? "Checks that Meets can reach the selected AI."
        ) {
            HStack(spacing: 8) {
                if isTesting {
                    ProgressView().controlSize(.small)
                }
                Button("Test") {
                    Task { await testConnection() }
                }
                .disabled(isTesting || !isEnabled)
            }
        }
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }

        do {
            try await AIService().testConnection()
            statusMessage = "Connection successful."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    // MARK: Meetings

    @ViewBuilder
    private var meetingsPage: some View {
        SettingsGroupHeader(title: "Meeting audio", subtitle: "Microphone transcription is always on.")

        SettingsRow(
            systemImage: "speaker.wave.2",
            title: "Capture meeting audio by default",
            subtitle: "Meets asks you to pick a display at meeting start so other participants are labeled separately from you. This uses the macOS share picker, not the Screen Recording permission dialog."
        ) {
            Toggle("Capture meeting audio by default", isOn: $captureMeetingAudioByDefault)
                .toggleStyle(.switch)
                .labelsHidden()
        }

        SettingsRow(
            systemImage: "lock.shield",
            title: "Screen & System Audio permission",
            subtitle: ScreenCapturePermission.troubleshootingMessage
        ) {
            Button("Open Settings") {
                ScreenCapturePermission.openSystemSettings()
            }
        }

        SettingsGroupHeader(
            title: "Call detection",
            subtitle: "Meets notices calls by which app is using your microphone, with no calendar access."
        )
        .padding(.top, 24)

        SettingsRow(
            systemImage: "phone.arrow.down.left",
            title: "Detect calls in any app or browser",
            subtitle: "While a browser is using the mic, Meets checks its open tabs for a meeting link, which macOS asks you to allow once per browser. Tab addresses are never saved. Detection only works while Meets is open."
        ) {
            Toggle("Detect calls in any app or browser", isOn: $detectMeetings)
                .toggleStyle(.switch)
                .labelsHidden()
        }

        SettingsRow(
            systemImage: "phone.down",
            title: "Stop recording when the call ends",
            subtitle: "Shows a countdown you can cancel before it stops."
        ) {
            Toggle("Stop recording when the call ends", isOn: $autoStopWhenCallEnds)
                .toggleStyle(.switch)
                .labelsHidden()
        }

        SettingsRow(
            systemImage: "timer",
            title: "Stop recording after no speech",
            subtitle: "A silent recording shows a one-minute countdown before it stops and is summarized. This doesn't apply while a recording is paused or during a detected call."
        ) {
            Picker("Stop recording after no speech for", selection: $idleRecordingStopMinutes) {
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
                Text("1 hour").tag(60)
                Text("Never").tag(0)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }

    // MARK: Overlay

    @ViewBuilder
    private var overlayPage: some View {
        SettingsGroupHeader(title: "Overlay", subtitle: "The floating window and notch you see during a call.")

        SettingsRow(systemImage: "circle.lefthalf.filled", title: "Opacity", subtitle: "How see-through the floating overlay is.") {
            Slider(value: $overlayOpacity, in: 0.6...1.0)
                .labelsHidden()
                .frame(width: 180)
        }
    }

    // MARK: Shortcuts

    @ViewBuilder
    private var shortcutsPage: some View {
        SettingsGroupHeader(title: "Keyboard shortcuts", subtitle: "Shortcuts that work in Meets.")

        shortcutGroup("During a call", [
            ("rectangle.on.rectangle", "Show or hide the overlay (works in any app)", ["⌘", "\\"]),
            ("photo", "Paste an image into a question", ["⌘", "V"]),
        ])
        shortcutGroup("Main window", [
            ("magnifyingglass", "Search meetings", ["⌘", "K"]),
            ("chevron.left", "Back", ["⌘", "["]),
            ("chevron.right", "Forward", ["⌘", "]"]),
            ("gearshape", "Open Settings", ["⌘", ","]),
        ])
        shortcutGroup("Meeting page", [
            ("text.magnifyingglass", "Find in meeting", ["⌘", "F"]),
            ("doc.text", "Show Summary", ["⌘", "1"]),
            ("text.quote", "Show Transcript", ["⌘", "2"]),
            ("sparkles", "Show Ask AI", ["⌘", "3"]),
        ])
    }

    private func shortcutGroup(_ title: String, _ items: [(String, String, [String])]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.top, 14)
                .padding(.bottom, 6)
            ForEach(items, id: \.1) { icon, label, keys in
                ShortcutRow(systemImage: icon, title: label, keys: keys)
            }
        }
    }
}

// MARK: - Building blocks

private struct SettingsNavItem: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? AppTheme.textPrimary : AppTheme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AppTheme.bgInput : (isHovered ? AppTheme.bgHover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SettingsGroupHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(.bottom, 14)
    }
}

/// An icon tile, a title and subtitle, and a control on the trailing edge.
private struct SettingsRow<Control: View>: View {
    let systemImage: String
    var iconTint: Color = AppTheme.textSecondary
    let title: String
    let subtitle: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 16))
                .foregroundStyle(iconTint)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(AppTheme.bgInput))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control
        }
        .padding(.vertical, 9)
    }
}

private struct SettingsFootnote: View {
    let text: String
    var color: Color = AppTheme.textSecondary

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .padding(.leading, 50)
            .padding(.bottom, 6)
    }
}

private struct ShortcutRow: View {
    let systemImage: String
    let title: String
    let keys: [String]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(minWidth: 24, minHeight: 24)
                        .padding(.horizontal, 2)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(AppTheme.bgInput))
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }
}

#Preview {
    SettingsView()
        .frame(width: 900, height: 640)
}
