import SwiftUI

struct OverlaySettingsView: View {
    @Bindable var sessionManager: SessionManager
    @State private var aiProvider = AppSettings.aiProvider
    @State private var overlayOpacity = AppSettings.overlayOpacity

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

            Section("Overlay") {
                Slider(value: $overlayOpacity, in: 0.6...1.0) {
                    Text("Opacity")
                }
                .onChange(of: overlayOpacity) { _, newValue in
                    AppSettings.overlayOpacity = newValue
                }
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
