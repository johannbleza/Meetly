import SwiftUI

struct OverlaySettingsView: View {
    @Bindable var sessionManager: SessionManager
    @State private var aiProvider = AppSettings.aiProvider
    @State private var overlayOpacity = AppSettings.overlayOpacity
    @State private var hideFromScreenShare = AppSettings.hideFromScreenShare
    @State private var reduceSpeakerBleed = AppSettings.reduceSpeakerBleed

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
                    sessionManager.setAIProvider(newValue)
                }

                Text(aiProvider.settingsDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !sessionManager.isAIAvailable {
                    Label(
                        sessionManager.aiAvailabilityMessage ?? "Selected provider is unavailable.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section("Meeting Audio") {
                Toggle("Ignore speaker audio on the mic", isOn: $reduceSpeakerBleed)
                    .onChange(of: reduceSpeakerBleed) { _, newValue in
                        sessionManager.setReduceSpeakerBleed(newValue)
                    }

                Text("Stops meeting audio playing through speakers from being transcribed as you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .frame(width: 300)
        .padding(.vertical, 4)
    }
}

#Preview {
    OverlaySettingsView(sessionManager: SessionManager())
        .padding()
}
