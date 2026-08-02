import SwiftUI

enum OverlayGlassStyle {
    static let cornerRadius: CGFloat = 14
    static let panelWidth: CGFloat = 420
    static let panelMinHeight: CGFloat = 280
    static let panelAbsoluteMinHeight: CGFloat = 180
    static let panelIdleMinHeight: CGFloat = 150
    static let panelMaxHeight: CGFloat = 640
    static let panelFoldedHeight: CGFloat = 48
    static let panelMaxHeightWithPendingImage: CGFloat = panelMaxHeight + 200

    /// Content area while listening or waiting on an answer.
    static let contentMaxHeightListening: CGFloat = 80
    /// Upper bound for the content area once an answer is visible.
    static let contentMaxHeightAnswer: CGFloat = 360

    static let resizeDuration: TimeInterval = 0.28
    static let resizeAnimation: Animation = .easeInOut(duration: resizeDuration)
    /// Ignore sub-pixel / layout thrash before growing the panel.
    static let resizeThreshold: CGFloat = 1.5

    /// Target content-area height for an AI answer, grown from the listening size.
    static func answerContentHeight(measured: CGFloat) -> CGFloat {
        let ideal = measured > 0 ? measured : contentMaxHeightListening
        return min(
            max(ideal, contentMaxHeightListening),
            contentMaxHeightAnswer
        )
    }

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
