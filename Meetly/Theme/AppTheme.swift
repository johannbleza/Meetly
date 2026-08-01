import SwiftUI

enum AppTheme {
    static let activityBarWidth: CGFloat = 48
    static let sidebarWidth: CGFloat = 260
    static let rowHeight: CGFloat = 44

    static let bgPrimary = Color(red: 0.118, green: 0.118, blue: 0.118)
    static let bgSidebar = Color(red: 0.145, green: 0.145, blue: 0.149)
    static let bgActivityBar = Color(red: 0.094, green: 0.094, blue: 0.094)
    static let bgHover = Color(red: 0.165, green: 0.176, blue: 0.180)
    static let bgSelected = Color(red: 0.035, green: 0.278, blue: 0.443)
    static let bgInput = Color(red: 0.196, green: 0.196, blue: 0.196)

    static let border = Color(red: 0.235, green: 0.235, blue: 0.235)
    static let textPrimary = Color(red: 0.800, green: 0.800, blue: 0.800)
    static let textSecondary = Color(red: 0.522, green: 0.522, blue: 0.522)
    static let accent = Color(red: 0.216, green: 0.580, blue: 1.000)
    static let danger = Color(red: 0.949, green: 0.388, blue: 0.388)
    static let success = Color(red: 0.400, green: 0.851, blue: 0.502)
    static let warning = Color(red: 0.984, green: 0.749, blue: 0.376)
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

struct AppListRowStyle: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(height: AppTheme.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor)
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(AppTheme.accent)
                        .frame(width: 2)
                }
            }
            .contentShape(Rectangle())
    }

    private var backgroundColor: Color {
        if isSelected {
            return AppTheme.bgSelected.opacity(0.55)
        }
        if isHovered {
            return AppTheme.bgHover
        }
        return .clear
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.appCaption)
                .foregroundStyle(AppTheme.textSecondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.appBody)
                .foregroundStyle(AppTheme.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(AppTheme.bgInput)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        }
    }
}

extension View {
    func appPanelBackground(_ color: Color = AppTheme.bgPrimary) -> some View {
        modifier(AppPanelBackground(color: color))
    }

    func appListRow(selected: Bool, hovered: Bool) -> some View {
        modifier(AppListRowStyle(isSelected: selected, isHovered: hovered))
    }
}
