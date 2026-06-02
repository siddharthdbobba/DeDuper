import Foundation
import Photos
import CoreGraphics
import ImageIO

/// Unified photo (and video) representation that works for both Photos library
/// assets and file-system items.
struct PhotoItem: Identifiable {
    enum Source {
        case asset(PHAsset)
        case fileURL(URL)
    }

    enum MediaKind {
        case still
        case livePhoto
        case video
    }

    let id: String
    let source: Source
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let mediaKind: MediaKind
    let isFavorite: Bool
    let burstIdentifier: String?
    /// Duration in seconds for videos; nil for stills.
    let duration: Double?
    /// On-disk byte size when readily available. For PHAssets this is filled in lazily.
    let fileByteSize: Int64?

    /// True iff this item should never be marked for deletion. Driven by the
    /// PHAsset favorite flag at the moment but extensible to user-marked
    /// protected items in the future.
    var isProtected: Bool { isFavorite }

    var isVideo: Bool { mediaKind == .video }

    /// Width-to-height ratio for layout. Falls back to 1:1 for videos and any
    /// item whose dimensions weren't resolved (pixelWidth or pixelHeight == 0).
    var aspectRatio: CGFloat {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }

    /// Best-effort on-disk size for "space freed" estimates: the real file size
    /// when known, otherwise a rough heuristic from pixel dimensions.
    var estimatedByteSize: Int64 {
        fileByteSize ?? Int64(pixelWidth * pixelHeight * 3) / 20
    }

    /// Returns a copy forced into the protected state, used to overlay
    /// album-level protection. Centralized here so adding a stored property to
    /// `PhotoItem` can't silently drop it from the copy.
    func markedProtected() -> PhotoItem {
        PhotoItem(
            id: id,
            source: source,
            creationDate: creationDate,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            mediaKind: mediaKind,
            isFavorite: true,
            burstIdentifier: burstIdentifier,
            duration: duration,
            fileByteSize: fileByteSize
        )
    }

    static func from(_ asset: PHAsset) -> PhotoItem {
        let kind: MediaKind
        switch asset.mediaType {
        case .video:
            kind = .video
        case .image:
            kind = asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .still
        default:
            kind = .still
        }
        return PhotoItem(
            id: asset.localIdentifier,
            source: .asset(asset),
            creationDate: asset.creationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            mediaKind: kind,
            isFavorite: asset.isFavorite,
            burstIdentifier: asset.burstIdentifier,
            duration: asset.mediaType == .video ? asset.duration : nil,
            fileByteSize: nil
        )
    }

    static func from(url: URL) -> PhotoItem {
        let ext = url.pathExtension.lowercased()
        if PhotoItem.videoExtensions.contains(ext) {
            // Skip the AVAsset sync calls (deprecated in macOS 13) — dimensions
            // and duration aren't required for dedup. We still capture file size
            // and creation date from the file system.
            let resourceValues = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            return PhotoItem(
                id: url.absoluteString,
                source: .fileURL(url),
                creationDate: resourceValues?.creationDate,
                pixelWidth: 0,
                pixelHeight: 0,
                mediaKind: .video,
                isFavorite: false,
                burstIdentifier: nil,
                duration: nil,
                fileByteSize: resourceValues?.fileSize.map { Int64($0) }
            )
        }
        let meta = imageMetadata(url: url)
        return PhotoItem(
            id: url.absoluteString,
            source: .fileURL(url),
            creationDate: meta.date,
            pixelWidth: meta.width,
            pixelHeight: meta.height,
            mediaKind: .still,
            isFavorite: false,
            burstIdentifier: nil,
            duration: nil,
            fileByteSize: meta.size
        )
    }

    // MARK: - Helpers

    private static func imageMetadata(url: URL) -> (date: Date?, width: Int, height: Int, size: Int64?) {
        var date: Date?
        var width = 0
        var height = 0
        var size: Int64?

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
        let resourceValues = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
        if date == nil { date = resourceValues?.creationDate }
        if let sizeBytes = resourceValues?.fileSize { size = Int64(sizeBytes) }
        return (date, width, height, size)
    }

}

private let exifDateFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
    return fmt
}()

// MARK: - Supported extensions

extension PhotoItem {
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png",
        "raw", "cr2", "cr3", "nef", "arw", "dng",
        "raf", "orf", "rw2", "tif", "tiff"
    ]

    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv"
    ]

    static let supportedExtensions: Set<String> = imageExtensions.union(videoExtensions)
}
