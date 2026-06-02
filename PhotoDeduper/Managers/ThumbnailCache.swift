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

    /// Shared between `startCachingImages` and `stopCachingImages`.
    /// `PHCachingImageManager` matches a prefetch by (targetSize, contentMode, options),
    /// so stop must pass the *same* options instance the start used — otherwise the
    /// prefetch is never cancelled and the cached working set grows across rescans.
    private let cachingOptions: PHImageRequestOptions = {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .fastFormat
        opts.resizeMode   = .fast
        opts.isNetworkAccessAllowed = true
        return opts
    }()

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
                options: cachingOptions
            )
        }
        warmedAssets = assets
        guard !assets.isEmpty else { return }
        manager.startCachingImages(
            for: assets,
            targetSize: Self.targetSize,
            contentMode: .aspectFit,
            options: cachingOptions
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

    /// Requests a full-resolution, high-quality image for the review grid, where
    /// the user inspects fine detail to choose which copy to keep. Opportunistic
    /// delivery paints the pre-warmed thumbnail first (instant), then replaces it
    /// with the full-quality original once decoded. `resizeMode = .none` +
    /// `PHImageManagerMaximumSize` returns the asset at its native resolution.
    @discardableResult
    func requestFullImage(
        for asset: PHAsset,
        completion: @escaping (PlatformImage?) -> Void
    ) -> PHImageRequestID {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic   // fast pre-warmed copy first, then full quality
        opts.resizeMode   = .none
        opts.isNetworkAccessAllowed = true
        return manager.requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
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
