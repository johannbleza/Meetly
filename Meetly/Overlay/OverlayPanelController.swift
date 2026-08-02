import AppKit
import SwiftUI

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayPanelController {
    static let shared = OverlayPanelController()

    private var panel: KeyablePanel?
    private weak var sessionManager: SessionManager?
    private var lastAppliedHeight: CGFloat = OverlayGlassStyle.panelMinHeight
    private var presentation: OverlayPresentation = .hidden

    private init() {}

    func configure(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        rebuildPanelIfNeeded()
    }

    func show() {
        rebuildPanelIfNeeded()
        if let panel {
            presentation = .expanded
            ScreenShareExclusion.apply(to: panel)
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func activateForInput() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            ScreenShareExclusion.apply(to: panel)
        }
    }

    func updatePreferredSize(_ size: CGSize) {
        guard let panel, presentation == .expanded else { return }
        applyHeight(
            min(
                max(size.height, OverlayGlassStyle.panelMinHeight),
                OverlayGlassStyle.panelMaxHeight
            ),
            to: panel
        )
    }

    func updateForPresentation(_ presentation: OverlayPresentation) {
        self.presentation = presentation
        guard let panel else { return }

        switch presentation {
        case .hidden:
            break
        case .folded:
            applyHeight(OverlayGlassStyle.panelFoldedHeight, to: panel)
        case .expanded:
            applyHeight(
                max(lastAppliedHeight, OverlayGlassStyle.panelMinHeight),
                to: panel
            )
        }
    }

    private func applyHeight(_ height: CGFloat, to panel: NSPanel) {
        let clampedHeight = height

        guard abs(clampedHeight - lastAppliedHeight) > 0.5 else { return }
        lastAppliedHeight = clampedHeight

        var frame = panel.frame
        let topEdge = frame.maxY
        frame.size = NSSize(width: OverlayGlassStyle.panelWidth, height: clampedHeight)
        frame.origin.y = topEdge - clampedHeight

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func rebuildPanelIfNeeded() {
        guard panel == nil, let sessionManager else { return }

        let contentView = OverlayView(sessionManager: sessionManager)
            .frame(width: OverlayGlassStyle.panelWidth)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let panel = KeyablePanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: OverlayGlassStyle.panelWidth,
                height: OverlayGlassStyle.panelMinHeight
            ),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSView()
        panel.contentView?.addSubview(hostingView)

        if let contentView = panel.contentView {
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }

        ScreenShareExclusion.apply(to: panel)
        positionPanelAtTopCenter(panel)
        self.panel = panel
    }

    private func positionPanelAtTopCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: screenFrame.midX - panelSize.width / 2,
            y: screenFrame.maxY - panelSize.height - 24
        )
        panel.setFrameOrigin(origin)
    }
}
