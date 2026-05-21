import Foundation
import Photos
import CoreGraphics
import ImageIO

/// Unified photo representation that works for both Photos library assets and file-system images.
struct PhotoItem: Identifiable {
    enum Source {
        case asset(PHAsset)
        case fileURL(URL)
    }

    let id: String
    let source: Source
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int

    static func from(_ asset: PHAsset) -> PhotoItem {
        PhotoItem(
            id: asset.localIdentifier,
            source: .asset(asset),
            creationDate: asset.creationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight
        )
    }

    static func from(url: URL) -> PhotoItem {
        let meta = imageMetadata(url: url)
        return PhotoItem(
            id: url.absoluteString,
            source: .fileURL(url),
            creationDate: meta.date,
            pixelWidth: meta.width,
            pixelHeight: meta.height
        )
    }

    // MARK: - Helpers

    private static func imageMetadata(url: URL) -> (date: Date?, width: Int, height: Int) {
        var date: Date?
        var width = 0
        var height = 0

        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            width  = props[kCGImagePropertyPixelWidth]  as? Int ?? 0
            height = props[kCGImagePropertyPixelHeight] as? Int ?? 0

            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let str  = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                date = exifDateFormatter.date(from: str)
            }
        }
        // Fall back to file system creation date.
        if date == nil {
            date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        }
        return (date, width, height)
    }
}

private let exifDateFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
    return fmt
}()

// MARK: - Supported image extensions

extension PhotoItem {
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png",
        "raw", "cr2", "cr3", "nef", "arw", "dng",
        "raf", "orf", "rw2", "tif", "tiff"
    ]
}
