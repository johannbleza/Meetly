import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var aiProvider = AppSettings.aiProvider
    @State private var textModel = AppSettings.geminiTextModel
    @State private var geminiWebSearchEnabled = AppSettings.geminiWebSearchEnabled
    @State private var overlayOpacity = AppSettings.overlayOpacity
    @State private var hideFromScreenShare = AppSettings.hideFromScreenShare
    @State private var apiKeyDraft = ""
    @State private var hasStoredAPIKey = GeminiConfig.hasAPIKey
    @State private var statusMessage: String?
    @State private var isTesting = false

    var body: some View {
        Form {
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

                Text("Live transcription always runs on-device with Apple Speech.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if aiProvider == .appleIntelligence {
                appleIntelligenceSection
            } else {
                geminiSection
            }

            Section("Meeting Audio") {
                Label("Microphone transcription is always on", systemImage: "mic.fill")
                    .foregroundStyle(.secondary)

                Text(ScreenCapturePermission.troubleshootingMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Open Screen & System Audio Settings") {
                    ScreenCapturePermission.openSystemSettings()
                }
            }

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
        .onAppear {
            refreshAPIKeyStatus()
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
    private var geminiSection: some View {
        Section("Gemini API") {
            if hasStoredAPIKey {
                Label("API key saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Add your Gemini API key", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            SecureField(hasStoredAPIKey ? "Enter a new key to replace the saved one" : "Gemini API key", text: $apiKeyDraft)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Save API Key") {
                    saveAPIKey()
                }
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Import .env…") {
                    importEnvFile()
                }
            }

            Text("Meetly runs in the App Sandbox, so it cannot read `.env` from the project folder automatically. Paste your key here or import a `.env` file once.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Text model", text: $textModel)
                .help("Default: gemini-2.5-flash")
                .onChange(of: textModel) { _, newValue in
                    AppSettings.geminiTextModel = newValue
                }

            Toggle("Allow web search for Q&A", isOn: $geminiWebSearchEnabled)
                .onChange(of: geminiWebSearchEnabled) { _, newValue in
                    AppSettings.geminiWebSearchEnabled = newValue
                }

            Text("Lets Gemini use Google Search when a question needs current facts or knowledge outside the meeting transcript. Summaries stay transcript-only.")
                .font(.caption)
                .foregroundStyle(.secondary)

            testConnectionButton(isEnabled: hasStoredAPIKey || !apiKeyDraft.isEmpty)
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

    private func saveAPIKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        GeminiKeyStore.setAPIKey(trimmed)
        apiKeyDraft = ""
        refreshAPIKeyStatus()
        statusMessage = "API key saved."
    }

    private func importEnvFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Gemini API Key"
        panel.message = "Choose a .env file containing GEMINI_API_KEY."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .data]
        panel.prompt = "Import"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let contents = try? String(contentsOf: url, encoding: .utf8),
              let key = DotEnv.value(for: "GEMINI_API_KEY", in: contents)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            statusMessage = "No GEMINI_API_KEY found in that file."
            return
        }

        GeminiKeyStore.setAPIKey(key)
        apiKeyDraft = ""
        refreshAPIKeyStatus()
        statusMessage = "Imported API key from \(url.lastPathComponent)."
    }

    private func refreshAPIKeyStatus() {
        hasStoredAPIKey = GeminiConfig.hasAPIKey
    }

    private func testConnection() async {
        if !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            GeminiKeyStore.setAPIKey(apiKeyDraft)
            apiKeyDraft = ""
            refreshAPIKeyStatus()
        }

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
