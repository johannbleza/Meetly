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
                VStack(alignment: .leading, spacing: 28) {
                    Text(page.title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    pageContent
                }
                .padding(.horizontal, 40)
                .padding(.top, 30)
                .padding(.bottom, 40)
                .frame(maxWidth: 680, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 1) {
            ForEach(SettingsPage.allCases, id: \.self) { item in
                SettingsNavItem(title: item.title, isSelected: page == item) {
                    page = item
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text("Meets \(appVersion)")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
                SettingsTextButton(title: "Quit Meets") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
        .padding(12)
        .padding(.top, 8)
        .frame(width: 190, alignment: .leading)
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
        SettingsSection("Privacy") {
            SettingsRow(
                title: "Hide from screen share",
                subtitle: hideFromScreenShare
                    ? "Meets's windows don't show up when you share your screen in Zoom, Google Meet and other apps."
                    : "Other people can see Meets's windows when you share your screen."
            ) {
                settingsSwitch("Hide from screen share", isOn: $hideFromScreenShare)
            }
        }

        SettingsSection("Startup and appearance") {
            SettingsRow(
                title: "Open at login",
                subtitle: openAtLoginError ?? "Meets starts automatically when you log in, so it can notice calls.",
                subtitleColor: openAtLoginError == nil ? AppTheme.textSecondary : AppTheme.danger
            ) {
                settingsSwitch("Open Meets at login", isOn: Binding(get: { openAtLogin }, set: { setOpenAtLogin($0) }))
            }

            SettingsRow(
                title: "Theme",
                subtitle: "How the main window looks. The overlay and notch always stay dark."
            ) {
                settingsMenu("Theme", selection: $appTheme) {
                    ForEach(AppTheme.Mode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }
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
        SettingsSection("Speech to text", footer: "Changes apply to your next meeting.") {
            SettingsRow(title: "Engine", subtitle: transcriptionEngine.settingsDescription) {
                settingsMenu("Engine", selection: $transcriptionEngine) {
                    ForEach(TranscriptionEngine.allCases) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
            }

            if transcriptionEngine == .whisper {
                SettingsRow(title: "Whisper model", subtitle: "Larger models are more accurate but slower.") {
                    settingsMenu("Model", selection: $whisperModel) {
                        ForEach(WhisperModel.allCases) { model in
                            Text(model.label).tag(model)
                        }
                    }
                }

                whisperModelStatus
            }
        }

        if transcriptionEngine == .whisper, let error = WhisperModelStore.shared.lastError {
            SettingsFootnote(text: error, color: AppTheme.danger)
        }
    }

    @ViewBuilder
    private var whisperModelStatus: some View {
        let store = WhisperModelStore.shared

        if store.installingModel == whisperModel, let phase = store.installPhase {
            switch phase {
            case .downloading(let fraction):
                SettingsRow(title: "Downloading model", subtitle: "\(Int(fraction * 100))% downloaded.") {
                    HStack(spacing: 12) {
                        ProgressView(value: fraction)
                            .frame(width: 120)
                        Button("Cancel") { store.cancelInstall() }
                    }
                }
            case .optimizing:
                SettingsRow(title: "Optimizing for this Mac", subtitle: "This can take a few minutes.") {
                    ProgressView().controlSize(.small)
                }
            }
        } else if store.isInstalled(whisperModel) {
            SettingsRow(
                title: "Model downloaded",
                subtitle: "Ready for your next meeting.",
                status: .init(text: "Ready", color: AppTheme.success)
            ) {
                Button("Remove") { store.remove(whisperModel) }
            }
        } else {
            SettingsRow(
                title: "Model not downloaded",
                subtitle: "Until it's downloaded, meetings use Apple Speech.",
                status: .init(text: "Not installed", color: AppTheme.warning)
            ) {
                Button("Download") { store.install(whisperModel) }
                    .disabled(store.installingModel != nil)
            }
        }
    }

    // MARK: AI

    @ViewBuilder
    private var aiPage: some View {
        SettingsSection("Provider", footer: "Used for live answers, summaries and action items.") {
            SettingsRow(title: "Provider", subtitle: aiProvider.settingsDescription) {
                settingsMenu("Provider", selection: $aiProvider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.label).tag(provider)
                    }
                }
            }

            if let agent = aiProvider.cliAgent {
                SettingsRow(
                    title: "\(agent.label) command-line tool",
                    subtitle: agent.isInstalled ? "Found the `\(agent.command)` command-line tool." : agent.setupMessage,
                    status: agent.isInstalled
                        ? .init(text: "Installed", color: AppTheme.success)
                        : .init(text: "Not found", color: AppTheme.warning)
                ) {
                    EmptyView()
                }
            } else {
                SettingsRow(
                    title: "Apple Intelligence",
                    subtitle: FoundationModelsClient.isAvailable
                        ? "AI answers and post-meeting summaries run on-device."
                        : (FoundationModelsClient.availabilityMessage ?? "Apple Intelligence is unavailable."),
                    status: FoundationModelsClient.isAvailable
                        ? .init(text: "Ready", color: AppTheme.success)
                        : .init(text: "Unavailable", color: AppTheme.warning)
                ) {
                    EmptyView()
                }
            }

            testConnectionRow(isEnabled: aiProvider.cliAgent?.isInstalled ?? FoundationModelsClient.isAvailable)
        }

        if let agent = aiProvider.cliAgent {
            SettingsSection("Options") {
                SettingsRow(
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
                    .frame(width: 160)
                }

                SettingsRow(
                    title: "Allow web search for questions",
                    subtitle: "Lets \(agent.label) search the web when a question needs current facts or knowledge outside the meeting transcript. Summaries stay transcript-only."
                ) {
                    settingsSwitch("Allow web search for questions", isOn: $aiWebSearchEnabled)
                }
            }
        }
    }

    private func testConnectionRow(isEnabled: Bool) -> some View {
        SettingsRow(
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
        SettingsSection("Meeting audio", footer: "Microphone transcription is always on.") {
            SettingsRow(
                title: "Capture meeting audio by default",
                subtitle: "Meets asks you to pick a display at meeting start so other participants are labeled separately from you. This uses the macOS share picker, not the Screen Recording permission dialog."
            ) {
                settingsSwitch("Capture meeting audio by default", isOn: $captureMeetingAudioByDefault)
            }

            SettingsRow(
                title: "Screen & System Audio permission",
                subtitle: ScreenCapturePermission.troubleshootingMessage
            ) {
                Button("Open Settings") {
                    ScreenCapturePermission.openSystemSettings()
                }
            }
        }

        SettingsSection(
            "Call detection",
            footer: "Meets notices calls by which app is using your microphone, with no calendar access."
        ) {
            SettingsRow(
                title: "Detect calls in any app or browser",
                subtitle: "While a browser is using the mic, Meets checks its open tabs for a meeting link, which macOS asks you to allow once per browser. Tab addresses are never saved. Detection only works while Meets is open."
            ) {
                settingsSwitch("Detect calls in any app or browser", isOn: $detectMeetings)
            }

            SettingsRow(
                title: "Stop recording when the call ends",
                subtitle: "Shows a countdown you can cancel before it stops."
            ) {
                settingsSwitch("Stop recording when the call ends", isOn: $autoStopWhenCallEnds)
            }

            SettingsRow(
                title: "Stop recording after no speech",
                subtitle: "A silent recording shows a one-minute countdown before it stops and is summarized. This doesn't apply while a recording is paused or during a detected call."
            ) {
                settingsMenu("Stop recording after no speech for", selection: $idleRecordingStopMinutes) {
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("Never").tag(0)
                }
            }
        }
    }

    // MARK: Overlay

    @ViewBuilder
    private var overlayPage: some View {
        SettingsSection("Floating overlay", footer: "The floating window and notch you see during a call.") {
            SettingsRow(title: "Opacity", subtitle: "How see-through the floating overlay is.") {
                Slider(value: $overlayOpacity, in: 0.6...1.0)
                    .labelsHidden()
                    .frame(width: 160)
            }
        }
    }

    // MARK: Shortcuts

    @ViewBuilder
    private var shortcutsPage: some View {
        shortcutSection("During a call", [
            ("Show or hide the overlay (works in any app)", ["⌘", "\\"]),
            ("Paste an image into a question", ["⌘", "V"]),
        ])
        shortcutSection("Main window", [
            ("Search meetings", ["⌘", "K"]),
            ("Back", ["⌘", "["]),
            ("Forward", ["⌘", "]"]),
            ("Open Settings", ["⌘", ","]),
        ])
        shortcutSection("Meeting page", [
            ("Find in meeting", ["⌘", "F"]),
            ("Show Summary", ["⌘", "1"]),
            ("Show Transcript", ["⌘", "2"]),
            ("Show Ask AI", ["⌘", "3"]),
        ])
    }

    private func shortcutSection(_ title: String, _ items: [(String, [String])]) -> some View {
        SettingsSection(title) {
            ForEach(items, id: \.0) { label, keys in
                ShortcutRow(title: label, keys: keys)
            }
        }
    }

    // MARK: Controls

    private func settingsSwitch(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
    }

    private func settingsMenu<Value: Hashable, Content: View>(
        _ label: String,
        selection: Binding<Value>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Picker(label, selection: selection, content: content)
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
    }
}

// MARK: - Building blocks

private struct SettingsNavItem: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? AppTheme.textPrimary : AppTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? AppTheme.bgInput : (isHovered ? AppTheme.bgHover : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Plain secondary text that turns primary on hover, for the sidebar's Quit.
private struct SettingsTextButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(isHovered ? AppTheme.textPrimary : AppTheme.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .onHover { isHovered = $0 }
    }
}

/// A titled group of rows in one bordered card, with hairlines between rows.
private struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.leading, 2)

            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Rectangle()
                                .fill(AppTheme.border)
                                .frame(height: 1)
                                .padding(.horizontal, 16)
                        }
                        row
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.bgPrimary))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.border, lineWidth: 1))

            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
        }
    }
}

/// A short colored word next to a row's title, such as "Ready" or "Not found".
private struct SettingsStatus {
    let text: String
    let color: Color
}

/// A title and subtitle, with a control on the trailing edge.
private struct SettingsRow<Control: View>: View {
    let title: String
    let subtitle: String?
    var subtitleColor: Color = AppTheme.textSecondary
    var status: SettingsStatus?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                    if let status {
                        Text(status.text)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(status.color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(status.color.opacity(0.12)))
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(subtitleColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct SettingsFootnote: View {
    let text: String
    var color: Color = AppTheme.textSecondary

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 2)
    }
}

private struct ShortcutRow: View {
    let title: String
    let keys: [String]

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(minWidth: 22, minHeight: 22)
                        .padding(.horizontal, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(AppTheme.border, lineWidth: 1)
                        )
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
    }
}

#Preview {
    SettingsView()
        .frame(width: 900, height: 640)
}
