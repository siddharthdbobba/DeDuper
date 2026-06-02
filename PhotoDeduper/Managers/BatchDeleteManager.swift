import Photos
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum DeleteError: LocalizedError {
    case accessDenied
    case trashFailed(URL, Error)
    case albumCreateFailed
    case noAssetsToOperateOn

    var errorDescription: String? {
        switch self {
        case .accessDenied: "Photo library access was denied."
        case .trashFailed(let url, let err): "Could not move \(url.lastPathComponent) to Trash: \(err.localizedDescription)"
        case .albumCreateFailed: "Could not create the review album in Photos."
        case .noAssetsToOperateOn: "No photo assets to operate on."
        }
    }
}

/// How a confirmed deletion is actually carried out.
enum DeletionMode {
    /// Photos library assets move to Recently Deleted (30-day recovery);
    /// file URLs move to macOS Trash. Original behaviour.
    case directDelete

    /// Photos library assets are *added* to a "PhotoDeduper Review" album so
    /// the user can audit them in Photos before manually deleting. File URLs
    /// still go to the Trash because no equivalent staging exists on disk.
    case holdForReview
}

/// Summary returned by `deleteItems` — carries enough information for the
/// undo banner and audit log to attribute work back to specific assets.
struct DeletionReceipt {
    /// Photos-library asset identifiers that were trashed. These can be
    /// recovered from "Recently Deleted" within 30 days.
    let trashedAssetIDs: [String]
    /// File URLs moved to macOS Trash.
    let trashedFileURLs: [URL]
    /// Asset identifiers that were instead added to the review album.
    let stagedAssetIDs: [String]
}

enum BatchDeleteManager {

    static let reviewAlbumName = "PhotoDeduper Review"

    /// Deletes (or stages) PhotoItems regardless of source.
    ///
    /// `folderScope` is the security-scoped folder URL a folder scan was started
    /// from. Held open across the file-trash work so child file URLs (which carry
    /// no bookmark of their own) stay accessible at delete time. `nil` for Photos
    /// library scans, which delete assets, not files.
    static func deleteItems(_ items: [PhotoItem], mode: DeletionMode = .directDelete, folderScope: URL? = nil) async throws -> DeletionReceipt {
        let assets = items.compactMap { item -> PHAsset? in
            if case .asset(let a) = item.source { return a }
            return nil
        }
        let urls = items.compactMap { item -> URL? in
            if case .fileURL(let u) = item.source { return u }
            return nil
        }

        switch mode {
        case .directDelete:
            if !assets.isEmpty { try await deletePhotoAssets(assets) }
            let trashedURLs = try trashFiles(urls, folderScope: folderScope)
            return DeletionReceipt(
                trashedAssetIDs: assets.map(\.localIdentifier),
                trashedFileURLs: trashedURLs,
                stagedAssetIDs: []
            )

        case .holdForReview:
            // Add assets to the review album; do not delete. File URLs still go
            // to Trash — there's no equivalent staging concept for disk files.
            if !assets.isEmpty {
                try await addToReviewAlbum(assets)
            }
            let trashedURLs = try trashFiles(urls, folderScope: folderScope)
            return DeletionReceipt(
                trashedAssetIDs: [],
                trashedFileURLs: trashedURLs,
                stagedAssetIDs: assets.map(\.localIdentifier)
            )
        }
    }

    // MARK: - Photos library deletion

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

    /// Opens Photos.app so the user can confirm restoration from Recently
    /// Deleted. Apple does NOT expose a public API to programmatically restore
    /// assets that have already been moved to the trash — only the Photos app
    /// itself can do that. So undo here is a navigation shortcut, not a true
    /// programmatic undo. The 30-day Recently-Deleted window protects the data.
    @discardableResult
    static func restoreFromRecentlyDeleted(assetIDs: [String]) async -> Bool {
        guard !assetIDs.isEmpty else { return false }
        await MainActor.run {
            if let url = URL(string: "photos://") {
#if os(macOS)
                _ = NSWorkspace.shared.open(url)
#else
                UIApplication.shared.open(url)
#endif
            }
        }
        return true
    }

    // MARK: - Review album

    private static func addToReviewAlbum(_ assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { throw DeleteError.noAssetsToOperateOn }
        let album = try await reviewAlbum()
        // Track whether the change request was actually created. If the album was
        // deleted between reviewAlbum() and performChanges, the guard fires an
        // early return but Photos still calls the completion with success=true.
        var requestCreated = false
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                guard let req = PHAssetCollectionChangeRequest(for: album) else { return }
                requestCreated = true
                req.addAssets(assets as NSArray)
            }, completionHandler: { success, error in
                if let error { cont.resume(throwing: error) }
                else if !success { cont.resume(throwing: DeleteError.accessDenied) }
                else if !requestCreated { cont.resume(throwing: DeleteError.albumCreateFailed) }
                else { cont.resume() }
            })
        }
    }

    /// Fetches the "PhotoDeduper Review" album, creating it if absent.
    static func reviewAlbum() async throws -> PHAssetCollection {
        if let existing = findReviewAlbum() { return existing }

        var createdID: String?
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: reviewAlbumName)
                createdID = req.placeholderForCreatedAssetCollection.localIdentifier
            }, completionHandler: { success, error in
                if let error { cont.resume(throwing: error) }
                else if !success { cont.resume(throwing: DeleteError.albumCreateFailed) }
                else { cont.resume() }
            })
        }

        guard let id = createdID,
              let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw DeleteError.albumCreateFailed
        }
        AppDefaults.reviewAlbumLocalID = id
        return album
    }

    private static func findReviewAlbum() -> PHAssetCollection? {
        guard let id = AppDefaults.reviewAlbumLocalID else { return nil }
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    }

    // MARK: - File-system deletion

    /// Trashes every URL while holding the parent folder's security scope open,
    /// so child URLs (which carry no bookmark of their own) stay accessible.
    private static func trashFiles(_ urls: [URL], folderScope: URL?) throws -> [URL] {
        guard !urls.isEmpty else { return [] }
        let scoped = folderScope?.startAccessingSecurityScopedResource() ?? false
        defer { if scoped { folderScope?.stopAccessingSecurityScopedResource() } }

        var trashed: [URL] = []
        for url in urls {
            try trashFile(url)
            trashed.append(url)
        }
        return trashed
    }

    private static func trashFile(_ url: URL) throws {
#if os(macOS)
        // Best-effort per-child scope: a child URL enumerated under a
        // security-scoped folder has no bookmark of its own, so this often
        // returns false even when access is valid via the parent scope held by
        // `trashFiles`. Don't hard-fail on it — let `trashItem` be the arbiter.
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            throw DeleteError.trashFailed(url, error)
        }
#else
        // iOS has no filesystem Trash and no arbitrary folder access;
        // file URL items never reach this code path in production.
        throw DeleteError.accessDenied
#endif
    }
}
