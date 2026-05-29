import SwiftUI
import ImageIO

// MARK: - Cross-platform image type alias
//
// Use `PlatformImage` everywhere instead of `NSImage` / `UIImage` directly.
// Use `Image(platformImage:)` in SwiftUI views instead of `Image(nsImage:)` / `Image(uiImage:)`.
// Use `.asCGImage` instead of `.cgImage(forProposedRect: nil, context: nil, hints: nil)`.
// Use `PlatformImage.from(cgImage:)` instead of `NSImage(cgImage:size:)` / `UIImage(cgImage:)`.

#if os(macOS)
import AppKit

typealias PlatformImage = NSImage

extension NSImage {
    /// Returns the underlying CGImage without the macOS-specific `forProposedRect:` arguments.
    var asCGImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Creates a PlatformImage from a CGImage.
    static func from(cgImage: CGImage) -> PlatformImage {
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

extension SwiftUI.Image {
    init(platformImage: PlatformImage) {
        self.init(nsImage: platformImage)
    }
}

#else
import UIKit

typealias PlatformImage = UIImage

extension UIImage {
    /// Returns the underlying CGImage — mirrors NSImage.asCGImage for cross-platform call sites.
    var asCGImage: CGImage? { cgImage }

    /// Creates a PlatformImage from a CGImage.
    static func from(cgImage: CGImage) -> PlatformImage {
        UIImage(cgImage: cgImage)
    }
}

extension SwiftUI.Image {
    init(platformImage: PlatformImage) {
        self.init(uiImage: platformImage)
    }
}
#endif

// MARK: - JPEG base64 encoding

extension CGImage {
    /// Encodes the image as a JPEG and returns it base64-encoded.
    /// Shared by the AI reviewers, which embed images as base64 JPEG in their request bodies.
    func jpegBase64(quality: CGFloat = 0.9) -> String? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, self, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data).base64EncodedString()
    }
}
