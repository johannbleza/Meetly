import AppKit
import SwiftUI

struct OverlayInputBar: View {
    @Binding var text: String
    @Binding var pendingImages: [ChatImageAttachment]
    let isDisabled: Bool
    let onSend: (String, [ChatImageAttachment]) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                PendingImageComposerPreview(pendingImages: $pendingImages)
                    .padding(.horizontal, 10)
                    .padding(.top, pendingImages.isEmpty ? 0 : 8)
                    .padding(.bottom, pendingImages.isEmpty ? 0 : 4)

                PasteAwareOverlayTextField(
                    text: $text,
                    isDisabled: isDisabled,
                    onImagePaste: { attachments in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            pendingImages.append(contentsOf: attachments)
                        }
                    },
                    onSubmit: sendIfPossible,
                    onFocus: {
                        OverlayPanelController.shared.activateForInput()
                    }
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            }

            Button(action: sendIfPossible) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(isDisabled || !canSend)
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.2), value: pendingImages.map(\.id))
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty
    }

    private func sendIfPossible() {
        guard !isDisabled, canSend else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = trimmed.isEmpty ? defaultImageQuestion : trimmed
        let images = pendingImages
        text = ""
        pendingImages = []
        onSend(question, images)
    }

    private var defaultImageQuestion: String {
        pendingImages.count > 1
            ? "What can you tell me about these images?"
            : "What can you tell me about this image?"
    }
}

#Preview {
    OverlayInputBar(
        text: .constant(""),
        pendingImages: .constant([]),
        isDisabled: false,
        onSend: { _, _ in }
    )
    .frame(width: 400)
    .padding()
    .overlayGlassPanel()
}
