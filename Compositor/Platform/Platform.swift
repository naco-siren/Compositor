#if os(macOS)
import AppKit
#else
import UIKit
#endif
import UniformTypeIdentifiers

// The few things the document model, the file formats and the renderers need from the platform's UI framework, kept
// here so the rest of Document, IO and Rendering builds for macOS and iPadOS alike. The Mac's behavior is exactly
// what it was when those files called AppKit themselves.

#if os(macOS)
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
typealias PlatformImage = NSImage
#else
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
typealias PlatformImage = UIImage

extension UIColor {
    /// AppKit's sRGB initializer. UIKit's own takes extended sRGB, which is the same color for components in 0...1.
    nonisolated convenience init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}
#endif

enum Platform {
    /// The system's accent color, for the transform box and the lines a move snaps to.
    static var accentColor: PlatformColor {
        #if os(macOS)
        .controlAccentColor
        #else
        .tintColor
        #endif
    }

    /// The alert sound for a command that can't run just now. iPadOS has no alert sound; it taps instead.
    static func beep() {
        #if os(macOS)
        NSSound.beep()
        #else
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }

    /// Makes `context` the one text and images are drawn into, drawing y down with glyphs upright, as a flipped
    /// view does — the way UIKit always draws. Balance with `popGraphicsContext()`.
    static func pushGraphicsContext(_ context: CGContext) {
        #if os(macOS)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        #else
        UIGraphicsPushContext(context)
        #endif
    }

    static func popGraphicsContext() {
        #if os(macOS)
        NSGraphicsContext.restoreGraphicsState()
        #else
        UIGraphicsPopContext()
        #endif
    }

    /// `image` shown `size` points across, as the panels draw their pictures.
    static func image(_ image: CGImage, size: CGSize) -> PlatformImage {
        #if os(macOS)
        NSImage(cgImage: image, size: size)
        #else
        UIImage(cgImage: image, scale: CGFloat(image.width) / max(1, size.width), orientation: .up)
        #endif
    }

    /// A picture of nothing, `size` points across, for when one can't be drawn.
    static func emptyImage(size: CGSize) -> PlatformImage {
        #if os(macOS)
        NSImage(size: size)
        #else
        UIGraphicsImageRenderer(size: size).image { _ in }
        #endif
    }
}

/// The general pasteboard, for pixels copied to other apps and pasted from them, and for the marker a copied layer
/// leaves so Paste in another project knows where it came from.
enum SystemPasteboard {
    static let layerType = "com.compositor.copied-layer"

    /// Counts every change to the pasteboard, by any app: a copy made here is still the latest while it's unchanged.
    static var changeCount: Int {
        #if os(macOS)
        NSPasteboard.general.changeCount
        #else
        UIPasteboard.general.changeCount
        #endif
    }

    /// Replaces the pasteboard's contents with a copied layer's marker, and returns the new change count.
    static func writeLayer(_ id: UUID) -> Int {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(id.uuidString, forType: NSPasteboard.PasteboardType(layerType))
        return pasteboard.changeCount
        #else
        UIPasteboard.general.setItems([[layerType: id.uuidString]])
        return UIPasteboard.general.changeCount
        #endif
    }

    /// Replaces the pasteboard's contents with `image` as PNG, for other apps, and returns the new change count.
    static func writeImage(_ image: CGImage) -> Int {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            pasteboard.setData(png, forType: .png)
        }
        return pasteboard.changeCount
        #else
        if let png = UIImage(cgImage: image).pngData() {
            UIPasteboard.general.setItems([[UTType.png.identifier: png]])
        } else {
            UIPasteboard.general.setItems([])
        }
        return UIPasteboard.general.changeCount
        #endif
    }

    static var hasImage: Bool {
        #if os(macOS)
        NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
        #else
        UIPasteboard.general.hasImages
        #endif
    }

    /// The image another app copied, if there is one. On iPad it's turned upright first: a photo copied in Photos comes
    /// as the camera stored it, with the turn that shows it upright kept beside the pixels rather than in them.
    static func image() -> CGImage? {
        #if os(macOS)
        NSImage(pasteboard: NSPasteboard.general)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        guard let image = UIPasteboard.general.image else { return nil }
        guard image.imageOrientation != .up else { return image.cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
        #endif
    }
}
