import SwiftUI

/// Motion state for the notch panel. What the notch *shows* comes from `SessionManager`;
/// this only holds how it moves: presence, hover, and the pull deformation.
@MainActor
@Observable
final class NotchModel {
    enum Phase: Equatable {
        /// Showing the overlay content.
        case docked
        /// The content was torn off into the floating overlay; the notch is retracting.
        case detached
        /// The floating overlay is being dragged nearby; the notch reaches toward it.
        case receptive
    }

    var metrics: NotchMetrics
    var phase: Phase = .docked
    /// False while the shape is shrunk back behind the hardware notch (or faded, for a virtual one).
    var isPresented = false
    var isHovering = false
    /// Typing a question: the notch stays open and holds keyboard focus until it's sent or cancelled.
    var isComposing = false
    /// The settings popover is open: stay expanded so it keeps its anchor.
    var isShowingSettings = false
    /// Extra height the hovered notch has been dragged open by, to scroll back through the transcript.
    var historyHeight: CGFloat = 0
    /// Set by the view: true while the hover controls or an AI answer show, the states that grow.
    var canGrowHistory = false
    /// Set by the view: an AI answer (or "Thinking…") is up. The transcript under it stays
    /// dragged open when the pointer leaves, since you read the answer without hovering.
    var isShowingAnswer = false

    /// Rubber-banded pull, in points (down and right are positive).
    var pull: CGSize = .zero
    /// The drop, threads and bridge drawn by `NotchLiquidLayer`, updated every display frame
    /// by `NotchLiquidDriver`. Only that layer reads it, so the rest of the notch doesn't
    /// re-render at frame rate.
    var liquid = NotchLiquid()
    /// 0...1 how strongly the notch reaches toward a nearby floating overlay.
    var reach: CGFloat = 0
    /// Briefly widens the notch when it swallows the overlay, then springs back to 0.
    var absorbPulse: CGFloat = 0

    /// The drawn body (without flares or pull), in window coordinates. Used for hit-testing.
    var shapeFrame: CGRect = .zero
    /// The bottom pill, in window coordinates; zero while it isn't showing. Picks the resize cursor.
    var grabberFrame: CGRect = .zero
    /// Buttons and chips, in window coordinates, so the pointer poll leaves their cursor alone.
    var controlFrames: [String: CGRect] = [:]

    init(metrics: NotchMetrics) {
        self.metrics = metrics
    }

    var isPulling: Bool {
        pull != .zero
    }
}
