import SwiftUI

enum OverlayGlassStyle {
    static let cornerRadius: CGFloat = 14
    static let panelWidth: CGFloat = 420
    static let panelMinHeight: CGFloat = 280
    static let panelIdleMinHeight: CGFloat = 150
    static let panelMaxHeight: CGFloat = 520
    static let panelFoldedHeight: CGFloat = 48
    static let contentMaxHeightCompact: CGFloat = 220

    @ViewBuilder
    static func background(cornerRadius: CGFloat = cornerRadius) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.clear)
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    static func stroke(cornerRadius: CGFloat = cornerRadius) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
    }
}

extension View {
    func overlayGlassPanel(cornerRadius: CGFloat = OverlayGlassStyle.cornerRadius) -> some View {
        background {
            OverlayGlassStyle.background(cornerRadius: cornerRadius)
        }
        .overlay {
            OverlayGlassStyle.stroke(cornerRadius: cornerRadius)
        }
    }
}
