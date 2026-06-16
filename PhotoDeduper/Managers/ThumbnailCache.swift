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
    /// enough for cards up to ~300 pt on 2× retina). Used for warmup + compact thumbs.
    static let targetSize = CGSize(width: 600, height: 600)

    /// Crisp-but-bounded size for review-grid cards. A single-photo group fills the
    /// detail pane (~700 pt → ~1400 px on 2× retina), so 1400 keeps even the largest
    /// tile sharp without paying the full-resolution-original decode cost per card.
    /// True full-res inspection lives in the lightbox, not the grid.
    static let displaySize = CGSize(width: 1400, height: 1400)

    private let manager = PHCachingImageManager()
    private var warmedAssets: [PHAsset] = []
    /// Tracks assets that have already been sent an iCloud download request,
    /// so progressive warmup (called once per group) doesn't fire redundant
    /// network requests for the same asset.
    private var prefetchedAssetIDs: Set<String> = []

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

    /// Triggers background downloads for any iCloud-only assets so they are
    /// available locally when the user scrolls to them in the review grid.
    /// Each asset gets a low-priority image request that tells Photos to fetch
    /// the bytes from iCloud if not already on-device.
    func prefetchICloudAssets(for groups: [PhotoGroup]) {
        let assets = groups
            .flatMap { $0.items }
            .compactMap { item -> PHAsset? in
                guard case .asset(let a) = item.source else { return nil }
                return prefetchedAssetIDs.contains(a.localIdentifier) ? nil : a
            }
        let newIDs = Set(assets.map { $0.localIdentifier })
        prefetchedAssetIDs.formUnion(newIDs)
        for asset in assets {
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: Self.targetSize,
                contentMode: .aspectFit,
                options: options
            ) { _, _ in }
        }
    }

    func stopAll() {
        manager.stopCachingImagesForAllAssets()
        warmedAssets = []
        prefetchedAssetIDs = []
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

    /// Requests a crisp, display-resolution image for the review grid. Opportunistic
    /// delivery paints the pre-warmed 600 px thumbnail first (instant) and then
    /// upgrades to the sharper `displaySize` copy once decoded. This deliberately
    /// does NOT decode the full-resolution original (`PHImageManagerMaximumSize` +
    /// `resizeMode: .none`) — that cost N full-res decodes per group and was the
    /// main source of slow grid loading. Full-res inspection is the lightbox's job.
    @discardableResult
    func requestDisplayImage(
        for asset: PHAsset,
        completion: @escaping (PlatformImage?) -> Void
    ) -> PHImageRequestID {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic   // fast pre-warmed copy first, then display quality
        opts.resizeMode   = .fast
        opts.isNetworkAccessAllowed = true
        return manager.requestImage(
            for: asset,
            targetSize: Self.displaySize,
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
