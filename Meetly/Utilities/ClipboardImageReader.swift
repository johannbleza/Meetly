import AppKit
import UniformTypeIdentifiers

enum ClipboardImageReader {
    private static let maxDimension: CGFloat = 2048
    private static let jpegQuality: CGFloat = 0.8

    static func readImages() -> [ChatImageAttachment] {
        let pasteboard = NSPasteboard.general
        var attachments: [ChatImageAttachment] = []

        if let objects = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) {
            for object in objects {
                guard let image = object as? NSImage, image.isValid,
                      let attachment = makeAttachment(from: normalizedImage(image)) else {
                    continue
                }
                attachments.append(attachment)
            }
            if !attachments.isEmpty {
                return attachments
            }
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL] {
            for url in urls {
                guard let type = UTType(filenameExtension: url.pathExtension),
                      type.conforms(to: .image),
                      let image = NSImage(contentsOf: url),
                      image.isValid,
                      let attachment = makeAttachment(from: normalizedImage(image)) else {
                    continue
                }
                attachments.append(attachment)
            }
            if !attachments.isEmpty {
                return attachments
            }
        }

        if let image = singleImageFromPasteboard(pasteboard),
           let attachment = makeAttachment(from: image) {
            return [attachment]
        }

        return []
    }

    private static func singleImageFromPasteboard(_ pasteboard: NSPasteboard) -> NSImage? {
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png,
            .tiff,
            NSPasteboard.PasteboardType(UTType.jpeg.identifier),
            NSPasteboard.PasteboardType(UTType.heic.identifier),
            NSPasteboard.PasteboardType(UTType.gif.identifier),
            NSPasteboard.PasteboardType(UTType.webP.identifier),
        ]

        for type in imageTypes {
            if let data = pasteboard.data(forType: type),
               let image = NSImage(data: data),
               image.isValid {
                return normalizedImage(image)
            }
        }

        for type in pasteboard.types ?? [] {
            guard let utType = UTType(type.rawValue), utType.conforms(to: .image) else { continue }
            if let data = pasteboard.data(forType: type),
               let image = NSImage(data: data),
               image.isValid {
                return normalizedImage(image)
            }
        }

        return nil
    }

    private static func normalizedImage(_ image: NSImage) -> NSImage {
        var proposedRect = NSRect(origin: .zero, size: image.size)

        if proposedRect.width <= 0 || proposedRect.height <= 0,
           let representation = image.representations.first {
            proposedRect.size = NSSize(
                width: max(representation.pixelsWide, 1),
                height: max(representation.pixelsHigh, 1)
            )
            image.size = proposedRect.size
        }

        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return image
        }

        return NSImage(cgImage: cgImage, size: proposedRect.size)
    }

    private static func makeAttachment(from image: NSImage) -> ChatImageAttachment? {
        let resized = resizeIfNeeded(image)
        guard let cgImage = resized.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = bitmap.representation(using: .jpeg, properties: [
            .compressionFactor: jpegQuality,
        ]) else {
            return nil
        }

        return ChatImageAttachment(data: jpegData)
    }

    private static func resizeIfNeeded(_ image: NSImage) -> NSImage {
        let size = image.size
        let longestSide = max(size.width, size.height)
        guard longestSide > maxDimension, longestSide > 0 else {
            return image
        }

        let scale = maxDimension / longestSide
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)

        let resized = NSImage(size: newSize)
        resized.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
        resized.unlockFocus()
        return resized
    }
}
