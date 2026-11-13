import SwiftUI

enum AppTheme {
    /// Widest the centered page column gets (meeting lists and meeting details).
    static let pageMaxWidth: CGFloat = 1040

    /// The main window's appearance setting. The overlay and notch are always dark.
    enum Mode: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        /// Nil follows the system appearance.
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    // Page and surfaces
    static let bgPrimary = adaptive(light: 0xFAFAFA, dark: (0.118, 0.118, 0.118))
    /// Cards, pills, popovers and the settings card.
    static let bgSidebar = adaptive(light: 0xFFFFFF, dark: (0.145, 0.145, 0.149))
    /// The greeting band at the top of the home page.
    static let bgBand = adaptive(light: 0xF3F3F3, dark: (0.145, 0.145, 0.149))
    static let bgHover = adaptive(light: 0xF0F0F0, dark: (0.165, 0.176, 0.180))
    /// Search fields, chips and segmented-control tracks.
    static let bgInput = adaptive(light: 0xEDEDED, dark: (0.196, 0.196, 0.196))
    /// The selected segment of a segmented control.
    static let bgSegment = adaptive(light: 0xFFFFFF, dark: (0.255, 0.255, 0.259))

    static let border = adaptive(light: 0xE5E5E5, dark: (0.235, 0.235, 0.235))
    static let textPrimary = adaptive(light: 0x161616, dark: (0.800, 0.800, 0.800))
    static let textSecondary = adaptive(light: 0x737373, dark: (0.522, 0.522, 0.522))

    static let accent = adaptive(light: 0x2F9BF0, dark: (0.216, 0.580, 1.000))
    /// Tinted fill behind accent text (Start Meeting, questions chip).
    static let accentSoft = adaptive(light: 0xE2F0FC, dark: (0.110, 0.220, 0.330))
    static let danger = adaptive(light: 0xE5484D, dark: (0.949, 0.388, 0.388))
    static let success = adaptive(light: 0x2EA44F, dark: (0.400, 0.851, 0.502))
    static let warning = adaptive(light: 0xD98E04, dark: (0.984, 0.749, 0.376))
    /// Search-match highlight; stays yellow in both appearances.
    static let highlight = Color(red: 0.984, green: 0.749, blue: 0.376)

    /// A color that resolves per appearance, so views follow the window's light or dark mode.
    private static func adaptive(light hex: UInt32, dark: (Double, Double, Double)) -> Color {
        let lightColor = NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
        let darkColor = NSColor(srgbRed: dark.0, green: dark.1, blue: dark.2, alpha: 1)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        })
    }
}

extension Font {
    static let appBody = Font.system(size: 13)
    static let appCaption = Font.system(size: 11)
    static let appSectionHeader = Font.system(size: 11, weight: .semibold)
    static let appTitle = Font.system(size: 20, weight: .semibold)
}

struct AppPanelBackground: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        content
            .background(color)
    }
}

struct AppDivider: View {
    var axis: Axis = .vertical

    var body: some View {
        Group {
            if axis == .vertical {
                Rectangle()
                    .fill(AppTheme.border)
                    .frame(width: 1)
            } else {
                Rectangle()
                    .fill(AppTheme.border)
                    .frame(height: 1)
            }
        }
    }
}

struct AppSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.appSectionHeader)
            .foregroundStyle(AppTheme.textSecondary)
            .tracking(0.6)
    }
}

struct AppSearchField: View {
    @Binding var text: String
    let placeholder: String
    var accessory: String? = nil
    var isFocused: FocusState<Bool>.Binding? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.appCaption)
                .foregroundStyle(AppTheme.textSecondary)
                .accessibilityHidden(true)

            textField

            if let accessory, !text.isEmpty {
                Text(accessory)
                    .font(.appCaption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .monospacedDigit()
                    .accessibilityLabel(accessory == "1" ? "1 match" : "\(accessory) matches")
            }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.appCaption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(AppTheme.bgInput)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
        .onExitCommand {
            if !text.isEmpty {
                text = ""
            } else {
                isFocused?.wrappedValue = false
            }
        }
    }

    private var borderColor: Color {
        isFocused?.wrappedValue == true ? AppTheme.accent : AppTheme.border
    }

    @ViewBuilder
    private var textField: some View {
        let field = TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.appBody)
            .foregroundStyle(AppTheme.textPrimary)
            .submitLabel(.search)

        if let isFocused {
            field.focused(isFocused)
        } else {
            field
        }
    }
}

extension View {
    func appPanelBackground(_ color: Color = AppTheme.bgPrimary) -> some View {
        modifier(AppPanelBackground(color: color))
    }
}
