import AppKit
import SwiftUI

private final class KeyablePanel: NSPanel {
    var onImagePaste: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "v",
           !ClipboardImageReader.readImages().isEmpty {
            onImagePaste?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class OverlayPanelController {
    static let shared = OverlayPanelController()

    private var panel: KeyablePanel?
    private weak var sessionManager: SessionManager?
    private var lastAppliedHeight: CGFloat = OverlayGlassStyle.panelMinHeight
    /// Height to restore when expanding; not overwritten by fold.
    private var lastExpandedHeight: CGFloat = OverlayGlassStyle.panelMinHeight
    private var preferredMaxHeight: CGFloat = OverlayGlassStyle.panelMaxHeight
    private var presentation: OverlayPresentation = .hidden
    private var onImagePaste: (() -> Void)?
    /// Ignore content-driven resize while the panel is animating fold/expand.
    private var suppressPreferredSizeUntil: Date?

    private init() {}

    func setImagePasteHandler(_ handler: (() -> Void)?) {
        onImagePaste = handler
        panel?.onImagePaste = { [weak self] in
            Task { @MainActor in
                self?.onImagePaste?()
            }
        }
    }

    func configure(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        OverlayKeyboardShortcutController.shared.configure(sessionManager: sessionManager)
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
        presentation = .hidden
        panel?.orderOut(nil)
    }

    func setPreferredMaxHeight(_ maxHeight: CGFloat) {
        guard maxHeight.isFinite, maxHeight > 0 else { return }
        preferredMaxHeight = maxHeight
    }

    func activateForInput() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            ScreenShareExclusion.apply(to: panel)
        }
    }

    func updatePreferredSize(_ size: CGSize, maxHeight: CGFloat) {
        guard let panel, presentation == .expanded else { return }
        if let suppressPreferredSizeUntil, Date() < suppressPreferredSizeUntil {
            return
        }
        applyHeight(
            clampedHeight(for: size.height, maxHeight: maxHeight),
            to: panel,
            tracksExpandedHeight: true
        )
    }

    func resetAppliedHeight() {
        lastAppliedHeight = OverlayGlassStyle.panelMinHeight
        lastExpandedHeight = OverlayGlassStyle.panelMinHeight
    }

    func updateForPresentation(_ presentation: OverlayPresentation, maxExpandedHeight: CGFloat? = nil) {
        self.presentation = presentation
        if let maxExpandedHeight {
            preferredMaxHeight = maxExpandedHeight
        }
        guard let panel else { return }

        switch presentation {
        case .hidden:
            break
        case .folded:
            // Remember the open height before collapsing so expand restores cleanly.
            if panel.frame.height > OverlayGlassStyle.panelFoldedHeight + OverlayGlassStyle.resizeThreshold {
                lastExpandedHeight = panel.frame.height
            }
            suppressPreferredSizeUntil = Date().addingTimeInterval(OverlayGlassStyle.resizeDuration + 0.05)
            applyHeight(
                OverlayGlassStyle.panelFoldedHeight,
                to: panel,
                tracksExpandedHeight: false
            )
        case .expanded:
            let baseHeight = sessionManager?.isMeetingActive == true
                ? lastExpandedHeight
                : OverlayGlassStyle.panelIdleMinHeight
            suppressPreferredSizeUntil = Date().addingTimeInterval(OverlayGlassStyle.resizeDuration + 0.05)
            applyHeight(
                clampedHeight(for: baseHeight, maxHeight: preferredMaxHeight),
                to: panel,
                tracksExpandedHeight: true
            )
        }
    }

    private var minimumExpandedHeight: CGFloat {
        sessionManager?.isMeetingActive == true
            ? OverlayGlassStyle.panelAbsoluteMinHeight
            : OverlayGlassStyle.panelIdleMinHeight
    }

    private func clampedHeight(for height: CGFloat, maxHeight: CGFloat) -> CGFloat {
        guard height.isFinite, maxHeight.isFinite, height > 0, maxHeight > 0 else {
            return minimumExpandedHeight
        }
        return min(
            max(height, minimumExpandedHeight),
            maxHeight
        )
    }

    private func applyHeight(
        _ height: CGFloat,
        to panel: NSPanel,
        tracksExpandedHeight: Bool
    ) {
        guard height.isFinite, height > 0 else { return }
        let currentPanelHeight = panel.frame.height
        let threshold = OverlayGlassStyle.resizeThreshold
        guard abs(height - lastAppliedHeight) > threshold
            || abs(height - currentPanelHeight) > threshold else { return }
        lastAppliedHeight = height
        if tracksExpandedHeight {
            lastExpandedHeight = height
        }

        var frame = panel.frame
        let topEdge = frame.maxY
        frame.size = NSSize(width: OverlayGlassStyle.panelWidth, height: height)
        frame.origin.y = topEdge - height

        NSAnimationContext.runAnimationGroup { context in
            context.duration = OverlayGlassStyle.resizeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
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
        panel.onImagePaste = { [weak self] in
            Task { @MainActor in
                self?.onImagePaste?()
            }
        }
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
