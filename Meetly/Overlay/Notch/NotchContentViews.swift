import SwiftUI

struct NotchTranscriptLine: Identifiable, Equatable {
    let id: String
    let sender: ChatMessageSender
    let text: String
    let isLive: Bool
}

/// Earlier lines dimmed on top, the newest line below in a fixed two-line box. The box never
/// changes height as a caption grows, and earlier lines only add height until the slots fill,
/// so the notch holds still while people talk instead of wobbling with every sentence.
struct NotchCaptionStack: View {
    let lines: [NotchTranscriptLine]
    let previousLineSlots: Int

    var body: some View {
        let latest = lines.last
        let previous = Array(lines.dropLast().suffix(previousLineSlots))

        VStack(alignment: .leading, spacing: 5) {
            ForEach(previous) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    NotchSpeakerTag(sender: line.sender, isDimmed: true)
                    Text(line.text)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let latest {
                    NotchSpeakerTag(sender: latest.sender)
                }
                NotchTeleprompterText(
                    text: latest?.text ?? "Listening…",
                    isPlaceholder: latest == nil
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The whole transcript in a scroll view, newest at the bottom, for when the notch is dragged open.
struct NotchTranscriptHistory: View {
    let lines: [NotchTranscriptLine]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 7) {
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        NotchSpeakerTag(sender: line.sender)
                        Text(line.text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(line.isLive ? 0.96 : 0.78))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .id(line.id)
                }
            }
            .padding(.vertical, 2)
        }
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.automatic)
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06)], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// Shows the end of a growing caption: new words push older ones up and out of view.
struct NotchTeleprompterText: View {
    let text: String
    var isPlaceholder = false

    @State private var textHeight: CGFloat = 0
    private let boxHeight: CGFloat = 36

    private var isOverflowing: Bool {
        textHeight > boxHeight + 1
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(.white.opacity(isPlaceholder ? 0.4 : 0.96))
            .lineSpacing(1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                textHeight = height
            }
            .frame(height: boxHeight, alignment: isOverflowing ? .bottom : .top)
            .clipped()
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: isOverflowing ? .clear : .black, location: 0),
                        .init(color: .black, location: isOverflowing ? 0.3 : 0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
    }
}

struct NotchSpeakerTag: View {
    let sender: ChatMessageSender
    var isDimmed = false

    var body: some View {
        Text(sender.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color.opacity(isDimmed ? 0.55 : 1))
            .frame(width: 34, alignment: .leading)
    }

    private var color: Color {
        switch sender {
        case .me, .user:
            Color(red: 0.45, green: 0.72, blue: 1.0)
        case .other:
            Color(red: 0.5, green: 0.9, blue: 0.68)
        case .assistant:
            Color(red: 0.8, green: 0.65, blue: 1.0)
        }
    }
}

struct NotchStatusGlyph: View {
    var sessionManager: SessionManager

    var body: some View {
        Group {
            if sessionManager.state == .paused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.yellow)
            } else if sessionManager.isMicrophoneMuted {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating)
            }
        }
        .frame(width: 12)
    }
}

struct NotchElapsedTime: View {
    var sessionManager: SessionManager

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(MeetingTimeFormatting.elapsed(sessionManager.sessionElapsedTime))
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
        }
    }
}

struct NotchIconButton: View {
    let systemImage: String
    let help: String
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint.opacity(0.9))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressStyle())
        .notchControl()
        .help(help)
    }
}

struct NotchChip: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(isEnabled ? 0.88 : 0.35))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.white.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(NotchPressStyle())
        .notchControl()
    }
}

/// Presses shrink a touch with a spring, so buttons feel like part of the same material.
struct NotchPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct NotchCapsuleButtonStyle: ButtonStyle {
    let isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                isProminent ? Color.accentColor : Color.white.opacity(0.12),
                in: Capsule()
            )
            .contentShape(Capsule())
            .notchControl()
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct NotchCountdownRow: View {
    let deadline: Date
    let reason: String
    let onKeepRecording: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let secondsLeft = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                Text("\(reason) Stopping in \(secondsLeft)s")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            Button("Keep recording", action: onKeepRecording)
                .buttonStyle(NotchCapsuleButtonStyle(isProminent: false))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// An answer that grows with its text up to a cap, then scrolls.
struct NotchAnswerText: View {
    let text: String

    @State private var textHeight: CGFloat = 0
    private let maxHeight: CGFloat = 260

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.95))
                .lineSpacing(2.5)
                // Not selectable: a drag on the answer pulls the notch off into the floating
                // overlay (which keeps the answer, selectable there) instead of selecting text.
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    textHeight = height
                }
        }
        .scrollIndicators(.automatic)
        .frame(height: min(max(textHeight, 18), maxHeight))
        .animation(OverlayPhysics.Springs.collapse, value: min(textHeight, maxHeight))
    }
}

/// Lets the notch's pointer poll know a control is here, so it shows the pointing hand
/// instead of the drag hand. Works without a `NotchModel` (e.g. in the floating overlay).
private struct NotchControlFrame: ViewModifier {
    @Environment(NotchModel.self) private var model: NotchModel?
    @State private var id = UUID().uuidString

    func body(content: Content) -> some View {
        content
            .pointerStyle(.link)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                model?.controlFrames[id] = frame
            }
            .onDisappear { model?.controlFrames[id] = nil }
    }
}

extension View {
    func notchControl() -> some View {
        modifier(NotchControlFrame())
    }
}
