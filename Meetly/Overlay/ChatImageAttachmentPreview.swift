import AppKit
import SwiftUI

extension ChatImageAttachment {
    var nsImage: NSImage? {
        NSImage(data: data)
    }
}

struct ChatImageAttachmentPreview: View {
    let attachment: ChatImageAttachment
    var style: Style = .composer
    var onRemove: (() -> Void)?

    enum Style {
        case composer
        case banner

        var tileSize: CGSize {
            switch self {
            case .composer: CGSize(width: 56, height: 56)
            case .banner: CGSize(width: 48, height: 48)
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .composer: 6
            case .banner: 8
            }
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let nsImage = attachment.nsImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: style.tileSize.width, height: style.tileSize.height)
            .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Remove image")
                .offset(x: 4, y: -4)
            }
        }
    }
}

struct PendingImageComposerPreview: View {
    @Binding var pendingImages: [ChatImageAttachment]

    var body: some View {
        if !pendingImages.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(pendingImages) { attachment in
                        ChatImageAttachmentPreview(attachment: attachment) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                pendingImages.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

#Preview {
    PendingImageComposerPreview(
        pendingImages: .constant([
            ChatImageAttachment(data: NSImage(systemSymbolName: "photo", accessibilityDescription: nil)!
                .tiffRepresentation ?? Data()),
            ChatImageAttachment(data: NSImage(systemSymbolName: "photo.fill", accessibilityDescription: nil)!
                .tiffRepresentation ?? Data()),
        ])
    )
    .padding(10)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .frame(width: 360)
    .padding()
}
