import SwiftUI

/// The "ready to record" prompt shown before a meeting, in the notch and in the floating
/// overlay alike: a status glyph, what's going on, and the record button on one row.
struct OverlayIdlePrompt: View {
    var sessionManager: SessionManager

    private var detected: DetectedMeeting? {
        sessionManager.detectedMeetingPrompt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                glyph

                VStack(alignment: .leading, spacing: 2) {
                    Text(detected?.promptTitle ?? "Ready to record")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(detected == nil
                        ? "Start when you're in your meeting."
                        : "Record and transcribe this call?")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                .fixedSize(horizontal: false, vertical: true)
                // Clicks on the text fall through to whatever drags the overlay underneath.
                .allowsHitTesting(false)

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    if detected != nil {
                        Button("Not now") {
                            sessionManager.dismissDetectedMeeting()
                        }
                        .buttonStyle(OverlayIdleButtonStyle(isProminent: false))
                    }
                    Button {
                        Task { await sessionManager.startMeeting() }
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(.red)
                                .frame(width: 7, height: 7)
                            Text("Record")
                        }
                    }
                    .buttonStyle(OverlayIdleButtonStyle(isProminent: true))
                    .help("Start recording")
                }
            }

            if let errorMessage = sessionManager.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var glyph: some View {
        Image(systemName: detected == nil ? "waveform" : "phone.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: 32, height: 32)
            .background(.white.opacity(0.1), in: Circle())
            .allowsHitTesting(false)
    }
}

/// White pill for the main action, quiet translucent pill for the secondary one.
struct OverlayIdleButtonStyle: ButtonStyle {
    let isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(isProminent ? Color.black : Color.white.opacity(0.85))
            .padding(.horizontal, 13)
            .frame(height: 28)
            .background(
                isProminent ? Color.white : Color.white.opacity(0.1),
                in: Capsule()
            )
            .contentShape(Capsule())
            .notchControl()
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
