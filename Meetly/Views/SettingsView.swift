import ServiceManagement
import SwiftUI

struct SettingsView: View {
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

    var body: some View {
        Form {
            transcriptionSection

            Section("AI Provider") {
                Picker("Provider", selection: $aiProvider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.label).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: aiProvider) { _, newValue in
                    AppSettings.aiProvider = newValue
                    statusMessage = nil
                }

                Text(aiProvider.settingsDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let agent = aiProvider.cliAgent {
                cliAgentSection(agent)
            } else {
                appleIntelligenceSection
            }

            Section("Meeting Audio") {
                Label("Microphone transcription is always on", systemImage: "mic.fill")
                    .foregroundStyle(.secondary)

                Toggle("Capture meeting audio by default", isOn: $captureMeetingAudioByDefault)
                    .onChange(of: captureMeetingAudioByDefault) { _, newValue in
                        AppSettings.captureMeetingAudioByDefault = newValue
                    }

                Text("When enabled, Meetly asks you to pick a display at meeting start so other participants are labeled separately from you. This uses the macOS share picker, not the Screen Recording permission dialog.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(ScreenCapturePermission.troubleshootingMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Open Screen & System Audio Settings") {
                    ScreenCapturePermission.openSystemSettings()
                }
            }

            meetingDetectionSection

            Section("Overlay") {
                Slider(value: $overlayOpacity, in: 0.6...1.0) {
                    Text("Opacity")
                }
                .onChange(of: overlayOpacity) { _, newValue in
                    AppSettings.overlayOpacity = newValue
                }

                Toggle("Hide from screen share", isOn: $hideFromScreenShare)
                    .onChange(of: hideFromScreenShare) { _, newValue in
                        AppSettings.hideFromScreenShare = newValue
                        ScreenShareExclusion.applyToAllWindows()
                    }

                Text("Keeps the overlay hidden from Zoom, Google Meet, and other screen sharing apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(AppTheme.bgSidebar)
        .navigationTitle("Settings")
        .frame(minWidth: 460, minHeight: 520)
    }

    private var meetingDetectionSection: some View {
        Section("Meeting Detection") {
            Toggle("Detect calls in any app or browser", isOn: $detectMeetings)
                .onChange(of: detectMeetings) { _, newValue in
                    AppSettings.detectMeetings = newValue
                }

            Toggle("Stop recording when the call ends", isOn: $autoStopWhenCallEnds)
                .onChange(of: autoStopWhenCallEnds) { _, newValue in
                    AppSettings.autoStopWhenCallEnds = newValue
                }

            Picker("Stop recording after no speech for", selection: $idleRecordingStopMinutes) {
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
                Text("1 hour").tag(60)
                Text("Never").tag(0)
            }
            .onChange(of: idleRecordingStopMinutes) { _, newValue in
                AppSettings.idleRecordingStopMinutes = newValue
            }

            Toggle("Open Meetly at login", isOn: Binding(
                get: { openAtLogin },
                set: { setOpenAtLogin($0) }
            ))

            if let openAtLoginError {
                Text(openAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("Meetly notices calls by which app is using your microphone, with no calendar access. While a browser is using the mic, Meetly checks its open tabs for a meeting link, which macOS asks you to allow once per browser. Tab addresses are never saved. Detection only works while Meetly is open.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("A silent recording shows a one-minute countdown before it stops and is summarized. This doesn't apply while a recording is paused or during a detected call.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

    @ViewBuilder
    private var transcriptionSection: some View {
        Section("Transcription") {
            Picker("Engine", selection: $transcriptionEngine) {
                ForEach(TranscriptionEngine.allCases) { engine in
                    Text(engine.label).tag(engine)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: transcriptionEngine) { _, newValue in
                AppSettings.transcriptionEngine = newValue
            }

            Text(transcriptionEngine.settingsDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            if transcriptionEngine == .whisper {
                Picker("Model", selection: $whisperModel) {
                    ForEach(WhisperModel.allCases) { model in
                        Text(model.label).tag(model)
                    }
                }
                .onChange(of: whisperModel) { _, newValue in
                    AppSettings.whisperModel = newValue
                }

                whisperModelStatus
            }

            Text("Changes apply to your next meeting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var whisperModelStatus: some View {
        let store = WhisperModelStore.shared

        if store.installingModel == whisperModel, let phase = store.installPhase {
            switch phase {
            case .downloading(let fraction):
                ProgressView("Downloading model…", value: fraction)

                Button("Cancel") {
                    store.cancelInstall()
                }
            case .optimizing:
                ProgressView("Optimizing for this Mac. This can take a few minutes…")
            }
        } else if store.isInstalled(whisperModel) {
            Label("Model ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

            Button("Remove Download") {
                store.remove(whisperModel)
            }
        } else {
            Label("Download this model to use it", systemImage: "arrow.down.circle")
                .foregroundStyle(.orange)

            Button("Download Model") {
                store.install(whisperModel)
            }
            .disabled(store.installingModel != nil)

            Text("Until it's ready, meetings use Apple Speech.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let error = store.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var appleIntelligenceSection: some View {
        Section("Apple Intelligence") {
            if FoundationModelsClient.isAvailable {
                Label("On-device model ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label(
                    FoundationModelsClient.availabilityMessage ?? "Apple Intelligence is unavailable.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }

            Text("AI answers and post-meeting summaries run on-device.")
                .font(.caption)
                .foregroundStyle(.secondary)

            testConnectionButton(isEnabled: FoundationModelsClient.isAvailable)
        }
    }

    @ViewBuilder
    private func cliAgentSection(_ agent: CLIAgent) -> some View {
        Section(agent.label) {
            if agent.isInstalled {
                Label("Found the `\(agent.command)` command-line tool", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label(agent.setupMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            switch agent {
            case .claude:
                TextField("Model", text: $claudeModel)
                    .help("A model name or alias such as sonnet, opus, or haiku.")
                    .onChange(of: claudeModel) { _, newValue in
                        AppSettings.claudeModel = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
            case .codex:
                TextField("Model", text: $codexModel, prompt: Text("Codex default"))
                    .help("Leave empty to use the default model for your Codex plan.")
                    .onChange(of: codexModel) { _, newValue in
                        AppSettings.codexModel = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
            }

            Toggle("Allow web search for Q&A", isOn: $aiWebSearchEnabled)
                .onChange(of: aiWebSearchEnabled) { _, newValue in
                    AppSettings.aiWebSearchEnabled = newValue
                }

            Text("Lets \(agent.label) search the web when a question needs current facts or knowledge outside the meeting transcript. Summaries stay transcript-only.")
                .font(.caption)
                .foregroundStyle(.secondary)

            testConnectionButton(isEnabled: agent.isInstalled)
        }
    }

    @ViewBuilder
    private func testConnectionButton(isEnabled: Bool) -> some View {
        HStack {
            Button("Test Connection") {
                Task { await testConnection() }
            }
            .disabled(isTesting || !isEnabled)
        }

        if isTesting {
            ProgressView()
                .controlSize(.small)
        }

        if let statusMessage {
            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
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
}

#Preview {
    SettingsView()
}
