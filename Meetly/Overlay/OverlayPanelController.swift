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
    /// Ignore content-driven resize while SwiftUI animates fold/expand.
    private var suppressPreferredSizeUntil: Date?
    private var isAnimatingContentResize = false
    private var preferImmediateSizeSync = false
    /// Deferred window-frame snap scheduled for the end of a fold animation.
    private var pendingPresentationWork: DispatchWorkItem?

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
        if isAnimatingContentResize { return }
        if let suppressPreferredSizeUntil, Date() < suppressPreferredSizeUntil {
            return
        }
        applyHeight(
            clampedHeight(for: size.height, maxHeight: maxHeight),
            to: panel,
            animated: !preferImmediateSizeSync
        )
        preferImmediateSizeSync = false
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
        pendingPresentationWork?.cancel()
        pendingPresentationWork = nil

        switch presentation {
        case .hidden:
            break
        case .folded:
            // Remember the open height before collapsing so expand restores cleanly.
            if panel.frame.height > OverlayGlassStyle.panelFoldedHeight + OverlayGlassStyle.resizeThreshold {
                lastExpandedHeight = panel.frame.height
            }
            suppressPreferredSizeUntil = Date().addingTimeInterval(OverlayGlassStyle.resizeDuration + 0.1)
            // SwiftUI animates the visual collapse inside the (transparent) window;
            // once it finishes, snap the window frame down without animating.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.presentation == .folded, let panel = self.panel else { return }
                self.setPanelHeightInstantly(OverlayGlassStyle.panelFoldedHeight, panel: panel)
            }
            pendingPresentationWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + OverlayGlassStyle.resizeDuration + 0.05,
                execute: work
            )
        case .expanded:
            let baseHeight = sessionManager?.isMeetingActive == true
                ? max(lastExpandedHeight, minimumExpandedHeight)
                : OverlayGlassStyle.panelIdleMinHeight
            suppressPreferredSizeUntil = Date().addingTimeInterval(OverlayGlassStyle.resizeDuration + 0.1)
            preferImmediateSizeSync = true
            // Grow the window immediately (it is invisible) so the SwiftUI
            // expansion animates open inside it without being clipped.
            let height = clampedHeight(for: baseHeight, maxHeight: preferredMaxHeight)
            setPanelHeightInstantly(height, panel: panel)
            lastExpandedHeight = height
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

    /// Sets the window frame without animation, keeping the top edge anchored.
    private func setPanelHeightInstantly(_ height: CGFloat, panel: NSPanel) {
        guard height.isFinite, height > 0 else { return }
        var frame = panel.frame
        let topEdge = frame.maxY
        frame.size = NSSize(width: OverlayGlassStyle.panelWidth, height: height)
        frame.origin.y = topEdge - height
        panel.setFrame(frame, display: true)
        lastAppliedHeight = height
    }

    /// Content-driven resize while expanded (e.g. an answer growing).
    private func applyHeight(_ height: CGFloat, to panel: NSPanel, animated: Bool) {
        guard height.isFinite, height > 0 else { return }
        let currentPanelHeight = panel.frame.height
        let threshold = OverlayGlassStyle.resizeThreshold
        guard abs(height - lastAppliedHeight) > threshold
            || abs(height - currentPanelHeight) > threshold else { return }
        lastAppliedHeight = height
        lastExpandedHeight = height

        var frame = panel.frame
        let topEdge = frame.maxY
        frame.size = NSSize(width: OverlayGlassStyle.panelWidth, height: height)
        frame.origin.y = topEdge - height

        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }

        isAnimatingContentResize = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = OverlayGlassStyle.resizeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        } completionHandler: {
            Task { @MainActor in
                self.isAnimatingContentResize = false
                self.lastAppliedHeight = panel.frame.height
            }
        }
    }

    private func rebuildPanelIfNeeded() {
        guard panel == nil, let sessionManager else { return }

        let contentView = OverlayView(sessionManager: sessionManager)
            .frame(width: OverlayGlassStyle.panelWidth)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.clipsToBounds = true
        // Panel frame is driven explicitly for fold/expand; don't let SwiftUI
        // intrinsic size push the window back open while folded.
        hostingView.sizingOptions = []

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
        let rootView = NSView()
        rootView.wantsLayer = true
        rootView.clipsToBounds = true
        panel.contentView = rootView
        rootView.addSubview(hostingView)

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
