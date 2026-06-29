import Photos
import CoreGraphics
import ImageIO
import AVFoundation

class PhotoLibraryManager {

    /// What media types a scan should include.
    enum MediaFilter {
        case stillsOnly
        case stillsAndVideos
        case videosOnly
    }

    // MARK: - Photos library

    func requestAuthorization() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Enumerates every image (and optionally video) in the user's Photos library.
    /// Runs on a background task so the main actor stays responsive and bails out
    /// promptly on cancellation.
    func fetchAllPhotos(filter: MediaFilter = .stillsOnly) async -> [PhotoItem] {
        let task = Task.detached(priority: .userInitiated) { () -> [PhotoItem] in
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            options.predicate = Self.predicate(for: filter)

            let result = PHAsset.fetchAssets(with: options)
            var items: [PhotoItem] = []
            items.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, stop in
                if Task.isCancelled {
                    stop.pointee = true
                    return
                }
                items.append(.from(asset))
            }
            return items
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Album browsing

    func fetchAlbums() -> [PhotoAlbum] {
        let imageOnlyPredicate = NSPredicate(
            format: "mediaType == %d", PHAssetMediaType.image.rawValue
        )
        let countOptions = PHFetchOptions()
        countOptions.predicate = imageOnlyPredicate

        var albums: [PhotoAlbum] = []

        // Smart albums — only the ones useful for a photographer.
        let usefulSubtypes: [PHAssetCollectionSubtype] = [
            .smartAlbumUserLibrary,
            .smartAlbumRecentlyAdded,
            .smartAlbumFavorites,
            .smartAlbumScreenshots,
            .smartAlbumSelfPortraits,
            .smartAlbumPanoramas,
            .smartAlbumDepthEffect,
            .smartAlbumLivePhotos,
            .smartAlbumLongExposures,
            .smartAlbumBursts,
        ]
        for subtype in usefulSubtypes {
            let result = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
            result.enumerateObjects { col, _, _ in
                let count = PHAsset.fetchAssets(in: col, options: countOptions).count
                guard count > 0, let title = col.localizedTitle else { return }
                albums.append(PhotoAlbum(
                    id: col.localIdentifier, title: title,
                    count: count, collection: col, collectionType: .smartAlbum
                ))
            }
        }

        // User-created albums.
        let userResult = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        userResult.enumerateObjects { col, _, _ in
            let count = PHAsset.fetchAssets(in: col, options: countOptions).count
            guard count > 0, let title = col.localizedTitle else { return }
            albums.append(PhotoAlbum(
                id: col.localIdentifier, title: title,
                count: count, collection: col, collectionType: .album
            ))
        }

        return albums
    }

    func fetchPhotos(from collection: PHAssetCollection, filter: MediaFilter = .stillsOnly) async -> [PhotoItem] {
        let task = Task.detached(priority: .userInitiated) { () -> [PhotoItem] in
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            options.predicate = Self.predicate(for: filter)

            let result = PHAsset.fetchAssets(in: collection, options: options)
            var items: [PhotoItem] = []
            items.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, stop in
                if Task.isCancelled {
                    stop.pointee = true
                    return
                }
                items.append(.from(asset))
            }
            return items
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Returns the local identifiers of every asset that belongs to any of the
    /// given collections. Used to expand "protected albums" into a fast lookup
    /// set the pipeline can consult per-item.
    func assetIDs(in collections: [PHAssetCollection]) -> Set<String> {
        var ids: Set<String> = []
        let options = PHFetchOptions()
        for col in collections {
            let result = PHAsset.fetchAssets(in: col, options: options)
            result.enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        }
        return ids
    }

    // MARK: - Folder scanning

    /// Recursively enumerates image (and optionally video) files in the given folder.
    /// Off-main + cooperatively cancellable for the same reasons as `fetchAllPhotos`.
    func scanFolder(_ url: URL, filter: MediaFilter = .stillsOnly) async -> [PhotoItem] {
        let task = Task.detached(priority: .userInitiated) { () -> [PhotoItem] in
            guard url.startAccessingSecurityScopedResource() else { return [] }
            defer { url.stopAccessingSecurityScopedResource() }

            var items: [PhotoItem] = []
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            let allowed: Set<String> = {
                switch filter {
                case .stillsOnly:       return PhotoItem.imageExtensions
                case .videosOnly:       return PhotoItem.videoExtensions
                case .stillsAndVideos:  return PhotoItem.supportedExtensions
                }
            }()

            while let fileURL = enumerator.nextObject() as? URL {
                if Task.isCancelled { return items }
                let ext = fileURL.pathExtension.lowercased()
                guard allowed.contains(ext) else { continue }
                let isFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                guard isFile else { continue }
                items.append(.from(url: fileURL))
            }

            // Sort by creation date to match Photos library behavior.
            return items.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Thumbnail loading

    static func loadThumbnail(for item: PhotoItem, size: CGSize) async -> CGImage? {
        switch item.source {
        case .asset(let asset):
            return await loadAssetThumbnail(asset, size: size)
        case .fileURL(let url):
            if item.isVideo {
                return await loadVideoThumbnail(url, size: size)
            }
            return loadFileThumbnail(url, size: size)
        }
    }

    private static func loadAssetThumbnail(_ asset: PHAsset, size: CGSize) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false

            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: image?.asCGImage)
            }
        }
    }

    private static func loadFileThumbnail(_ url: URL, size: CGSize) -> CGImage? {
        // Don't gate on the return value. These are CHILD file URLs enumerated
        // from a security-scoped folder; they are not themselves security-scoped,
        // so `startAccessingSecurityScopedResource()` returns false for them even
        // though the file is perfectly readable while the PARENT folder's scope
        // is active (ReviewViewModel holds it open for the whole session). The old
        // `guard … else { return nil }` therefore failed every folder thumbnail →
        // nil hashes → no duplicates found. Start best-effort and only balance the
        // stop when it actually succeeded; attempt the read regardless.
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let maxDim = Int(max(size.width, size.height))
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDim,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// Generates a still thumbnail from a video file (single keyframe near the start).
    private static func loadVideoThumbnail(_ url: URL, size: CGSize) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }

            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = size

            // Half-second in; some files have a black first frame.
            let time = CMTime(seconds: 0.5, preferredTimescale: 600)
            return try? generator.copyCGImage(at: time, actualTime: nil)
        }.value
    }

    // MARK: - Private helpers

    private static func predicate(for filter: MediaFilter) -> NSPredicate {
        switch filter {
        case .stillsOnly:
            return NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        case .videosOnly:
            return NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        case .stillsAndVideos:
            return NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
            )
        }
    }
}
