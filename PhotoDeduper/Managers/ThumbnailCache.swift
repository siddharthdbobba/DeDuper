import Photos

/// Pre-warms and serves thumbnails for the review grid via `PHCachingImageManager`.
///
/// `PHCachingImageManager` queues decode/scale work ahead of time so that when
/// a `PhotoCard` appears its image is already in the system thumbnail cache and
/// returns near-instantly instead of loading cold.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    /// 600 pt target gives comfortable pixel headroom for portrait photos displayed
    /// with their natural aspect ratio (a 3:4 portrait at this size returns ~450×600 px,
    /// enough for cards up to ~300 pt on 2× retina).
    static let targetSize = CGSize(width: 600, height: 600)

    private let manager = PHCachingImageManager()
    private var warmedAssets: [PHAsset] = []

    private init() {}

    // MARK: - Cache control

    /// Pre-loads thumbnails for all PHAsset-backed items in `groups`.
    /// Stops any previous pass first to avoid memory pressure.
    func warmup(for groups: [PhotoGroup]) {
        let assets = groups
            .flatMap(\.items)
            .compactMap { item -> PHAsset? in
                guard case .asset(let a) = item.source else { return nil }
                return a
            }
        if !warmedAssets.isEmpty {
            manager.stopCachingImages(
                for: warmedAssets,
                targetSize: Self.targetSize,
                contentMode: .aspectFit,
                options: nil
            )
        }
        warmedAssets = assets
        guard !assets.isEmpty else { return }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .fastFormat
        opts.resizeMode   = .fast
        opts.isNetworkAccessAllowed = true
        manager.startCachingImages(
            for: assets,
            targetSize: Self.targetSize,
            contentMode: .aspectFit,
            options: opts
        )
    }

    func stopAll() {
        manager.stopCachingImagesForAllAssets()
        warmedAssets = []
    }

    // MARK: - Image requests

    /// Requests a thumbnail, hitting the pre-warmed cache when available.
    @discardableResult
    func requestImage(
        for asset: PHAsset,
        completion: @escaping (PlatformImage?) -> Void
    ) -> PHImageRequestID {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic   // fast degraded copy first, then full
        opts.resizeMode   = .fast
        opts.isNetworkAccessAllowed = true
        return manager.requestImage(
            for: asset,
            targetSize: Self.targetSize,
            contentMode: .aspectFit,
            options: opts
        ) { img, _ in
            completion(img)
        }
    }

    func cancelRequest(_ id: PHImageRequestID) {
        manager.cancelImageRequest(id)
    }
}
