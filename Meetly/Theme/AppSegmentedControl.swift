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
    /// Animates the change. Nil leaves it to the binding, for selections whose own setter
    /// animates (content that slides by direction).
    var animation: Animation? = .snappy(duration: 0.22)

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                let isSelected = segment.value == selection
                Button {
                    if let animation {
                        withAnimation(animation) { selection = segment.value }
                    } else {
                        selection = segment.value
                    }
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
                                .foregroundStyle(badge > 0 ? AppTheme.textPrimary : AppTheme.textSecondary)
                        }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? AppTheme.textPrimary : AppTheme.textSecondary)
                    // The color swaps without interpolating the text: an interpolated label is
                    // drawn apart from the control, so it trailed behind when the control moved
                    // in the same animation (the home page's gliding list controls).
                    .contentTransition(.identity)
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
                .clickableCursor()
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
