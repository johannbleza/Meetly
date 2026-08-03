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
    private var presentation: OverlayPresentation = .hidden
    private var onImagePaste: (() -> Void)?

    /// The window is a fixed-size transparent canvas; SwiftUI draws the glass
    /// panel (at whatever size the content needs) top-anchored inside it. The
    /// window itself never resizes, so the UI can never be clipped by it.
    private static let canvasHeight: CGFloat = OverlayGlassStyle.panelMaxHeightWithPendingImage

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

    func activateForInput() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            ScreenShareExclusion.apply(to: panel)
        }
    }

    func updateForPresentation(_ presentation: OverlayPresentation, maxExpandedHeight: CGFloat? = nil) {
        // Fold/expand is purely a SwiftUI animation; the window never resizes.
        self.presentation = presentation
    }

    private func rebuildPanelIfNeeded() {
        guard panel == nil, let sessionManager else { return }

        let contentView = OverlayView(sessionManager: sessionManager)
            .frame(width: OverlayGlassStyle.panelWidth)
            .preferredColorScheme(.dark)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        // The window is a fixed-size canvas; SwiftUI sizes the visible panel.
        hostingView.sizingOptions = []

        let panel = KeyablePanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: OverlayGlassStyle.panelWidth,
                height: Self.canvasHeight
            ),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Disabled so the bottom resize handle can receive drags. Move via the toolbar drag region.
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // Keep liquid glass on the dark variant regardless of system appearance.
        panel.appearance = NSAppearance(named: .darkAqua)
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
