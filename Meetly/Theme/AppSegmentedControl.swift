import SwiftUI

/// A segmented control with a gray track and a raised white selected segment.
/// Used for the meeting tabs, the Meetings / Archived filter and the list / grid toggle.
struct AppSegmentedControl<Value: Hashable>: View {
    struct Segment: Identifiable {
        let value: Value
        var title: String?
        var systemImage: String?
        /// A count shown after the title, such as search matches.
        var badge: Int?
        var help: String?

        var id: Value { value }
    }

    @Binding var selection: Value
    let segments: [Segment]
    var height: CGFloat = 28

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                let isSelected = segment.value == selection
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = segment.value }
                } label: {
                    HStack(spacing: 5) {
                        if let systemImage = segment.systemImage {
                            Image(systemName: systemImage)
                                .font(.system(size: 12, weight: .medium))
                        }
                        if let title = segment.title {
                            Text(title)
                        }
                        if let badge = segment.badge {
                            Text("\(badge)")
                                .font(.system(size: 10, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(badge > 0 ? AppTheme.accent : AppTheme.textSecondary)
                        }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? AppTheme.textPrimary : AppTheme.textSecondary)
                    .padding(.horizontal, segment.title == nil ? 8 : 12)
                    .frame(height: height - 6)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(AppTheme.bgSegment)
                                .shadow(color: .black.opacity(0.08), radius: 1.5, y: 0.5)
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(segment.help ?? segment.title ?? "")
                .accessibilityLabel(segment.title ?? segment.help ?? "")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.bgInput)
        )
        .fixedSize()
    }
}
