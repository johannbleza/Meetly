import SwiftUI

struct OverlayInputBar: View {
    @Binding var text: String
    let isDisabled: Bool
    let onSend: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Ask about the conversation…", text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .disabled(isDisabled)
                .onSubmit(sendIfPossible)
                .onTapGesture {
                    OverlayPanelController.shared.activateForInput()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Button(action: sendIfPossible) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(isDisabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 8)
    }

    private func sendIfPossible() {
        guard !isDisabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        text = ""
        onSend(trimmed)
    }
}

#Preview {
    OverlayInputBar(text: .constant(""), isDisabled: false, onSend: { _ in })
        .frame(width: 400)
        .padding()
        .overlayGlassPanel()
}
