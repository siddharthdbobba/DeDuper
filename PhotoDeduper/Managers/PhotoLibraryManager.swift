import Photos
import CoreGraphics
import ImageIO

class PhotoLibraryManager {

    // MARK: - Photos library

    func requestAuthorization() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Enumerates every image in the user's Photos library. Runs on a background
    /// task so the main actor stays responsive (Cancel button must remain clickable)
    /// and bails out promptly on cancellation.
    func fetchAllPhotos() async -> [PhotoItem] {
        let task = Task.detached(priority: .userInitiated) { () -> [PhotoItem] in
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

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

    func fetchPhotos(from collection: PHAssetCollection) async -> [PhotoItem] {
        let task = Task.detached(priority: .userInitiated) { () -> [PhotoItem] in
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

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

    // MARK: - Folder scanning

    /// Recursively enumerates image files in the given folder. Off-main + cooperatively
    /// cancellable for the same reasons as `fetchAllPhotos`.
    func scanFolder(_ url: URL) async -> [PhotoItem] {
        let task = Task.detached(priority: .userInitiated) { () -> [PhotoItem] in
            guard url.startAccessingSecurityScopedResource() else { return [] }
            defer { url.stopAccessingSecurityScopedResource() }

            var items: [PhotoItem] = []
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            for case let fileURL as URL in enumerator {
                if Task.isCancelled { return items }
                let ext = fileURL.pathExtension.lowercased()
                guard PhotoItem.imageExtensions.contains(ext) else { continue }
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
                continuation.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
    }

    private static func loadFileThumbnail(_ url: URL, size: CGSize) -> CGImage? {
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let maxDim = Int(max(size.width, size.height))
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDim,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }
}
