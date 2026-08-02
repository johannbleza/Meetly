import SwiftUI

struct MeetingQAInputBar: View {
    @Binding var text: String
    let isDisabled: Bool
    let onSend: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Ask about this meeting…", text: $text)
                .textFieldStyle(.plain)
                .font(.appBody)
                .foregroundStyle(AppTheme.textPrimary)
                .disabled(isDisabled)
                .onSubmit(sendIfPossible)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(AppTheme.bgInput)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 1)
                }

            Button(action: sendIfPossible) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AppTheme.accent)
            }
            .buttonStyle(.borderless)
            .disabled(isDisabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppTheme.bgSidebar)
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
    MeetingQAInputBar(text: .constant(""), isDisabled: false, onSend: { _ in })
        .frame(width: 600)
        .preferredColorScheme(.dark)
}
