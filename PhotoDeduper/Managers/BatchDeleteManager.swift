import Photos

enum DeleteError: LocalizedError {
    case accessDenied
    case trashFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .accessDenied: "Photo library access was denied."
        case .trashFailed(let url, let err): "Could not move \(url.lastPathComponent) to Trash: \(err.localizedDescription)"
        }
    }
}

enum BatchDeleteManager {
    /// Deletes PhotoItems regardless of source.
    /// - Photos library assets → moved to "Recently Deleted" (recoverable for 30 days)
    /// - File URLs → moved to macOS Trash (recoverable via Finder)
    static func deleteItems(_ items: [PhotoItem]) async throws {
        let assets = items.compactMap { item -> PHAsset? in
            if case .asset(let a) = item.source { return a }
            return nil
        }
        let urls = items.compactMap { item -> URL? in
            if case .fileURL(let u) = item.source { return u }
            return nil
        }

        if !assets.isEmpty { try await deletePhotoAssets(assets) }
        for url in urls { try trashFile(url) }
    }

    private static func deletePhotoAssets(_ assets: [PHAsset]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }, completionHandler: { success, error in
                if let error { cont.resume(throwing: error) }
                else if !success { cont.resume(throwing: DeleteError.accessDenied) }
                else { cont.resume() }
            })
        }
    }

    private static func trashFile(_ url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw DeleteError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            throw DeleteError.trashFailed(url, error)
        }
    }
}
