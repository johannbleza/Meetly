import AppKit
import SwiftUI

struct PasteAwareOverlayTextField: NSViewRepresentable {
    @Binding var text: String
    var isDisabled: Bool
    var onImagePaste: ([ChatImageAttachment]) -> Void
    var onSubmit: () -> Void
    var onFocus: () -> Void

    func makeNSView(context: Context) -> PasteImageNSTextField {
        let field = PasteImageNSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        field.placeholderString = "Ask about the conversation… (⌘V to paste images)"
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        field.delegate = context.coordinator
        field.onImagePaste = onImagePaste
        return field
    }

    func updateNSView(_ nsView: PasteImageNSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.isEnabled = !isDisabled
        nsView.onImagePaste = onImagePaste
        context.coordinator.onImagePaste = onImagePaste
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onFocus = onFocus
        context.coordinator.onTextChange = { text = $0 }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onTextChange: { text = $0 },
            onImagePaste: onImagePaste,
            onSubmit: onSubmit,
            onFocus: onFocus
        )
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onTextChange: (String) -> Void
        var onImagePaste: ([ChatImageAttachment]) -> Void
        var onSubmit: () -> Void
        var onFocus: () -> Void

        private let pasteSelector = Selector("paste:")

        init(
            onTextChange: @escaping (String) -> Void,
            onImagePaste: @escaping ([ChatImageAttachment]) -> Void,
            onSubmit: @escaping () -> Void,
            onFocus: @escaping () -> Void
        ) {
            self.onTextChange = onTextChange
            self.onImagePaste = onImagePaste
            self.onSubmit = onSubmit
            self.onFocus = onFocus
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            onTextChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == pasteSelector {
                let attachments = ClipboardImageReader.readImages()
                guard !attachments.isEmpty else { return false }
                onImagePaste(attachments)
                return true
            }

            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            }

            return false
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            onFocus()
        }
    }
}

final class PasteImageNSTextField: NSTextField {
    var onImagePaste: (([ChatImageAttachment]) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isEnabled else { return super.performKeyEquivalent(with: event) }

        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            let attachments = ClipboardImageReader.readImages()
            guard !attachments.isEmpty else {
                return super.performKeyEquivalent(with: event)
            }
            onImagePaste?(attachments)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}
