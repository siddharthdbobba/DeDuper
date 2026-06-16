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

/// A file that was moved to the macOS Trash: where it came from and where it
/// landed, so undo can move it straight back.
struct TrashedFile {
    let originalURL: URL
    let trashedURL: URL
}

/// Summary returned by `deleteItems` — carries enough information for the
/// undo banner and audit log to attribute work back to specific assets.
struct DeletionReceipt {
    /// Photos-library asset identifiers that were trashed. These can be
    /// recovered from "Recently Deleted" within 30 days.
    let trashedAssetIDs: [String]
    /// Files moved to macOS Trash, with their Trash destinations for undo.
    let trashedFiles: [TrashedFile]
    /// Asset identifiers that were instead added to the review album.
    let stagedAssetIDs: [String]
    /// Number of file URLs that could NOT be trashed. Successes above are
    /// still valid; the ViewModel decides how to surface partial failure.
    let failedCount: Int
    /// localizedDescription of the first failure, for user-facing messaging.
    let firstFailureDescription: String?

    /// Ready-made error copy for the nothing-succeeded case, shared by both
    /// delete paths (per-group and confirm-all) so the wording can't drift.
    /// `nil` whenever at least one item was deleted/staged — callers surface
    /// partial failure with a non-blocking notice instead of an error state.
    var allFailedMessage: String? {
        guard failedCount > 0,
              trashedAssetIDs.isEmpty, trashedFiles.isEmpty, stagedAssetIDs.isEmpty else { return nil }
        return "Deleted 0, failed \(failedCount): \(firstFailureDescription ?? "Unknown error")"
    }

    /// Returns this receipt with `previous`'s undo handles merged in.
    ///
    /// Used when a new deletion lands while an undo banner is still active:
    /// overwriting `lastReceipt` would discard the previous batch's
    /// `TrashedFile` entries — the only handles that can move those files back
    /// out of the Trash — so the new receipt absorbs them instead, letting one
    /// Undo restore both batches. Entries are deduped by original URL / asset
    /// ID (self's entries win). `failedCount` and `firstFailureDescription`
    /// are NOT merged: they describe the latest attempt only, and callers key
    /// retry/partial-failure behaviour off them.
    func absorbing(_ previous: DeletionReceipt?) -> DeletionReceipt {
        guard let previous else { return self }
        var mergedFiles = trashedFiles
        let knownOriginals = Set(mergedFiles.map(\.originalURL))
        mergedFiles.append(contentsOf: previous.trashedFiles.filter { !knownOriginals.contains($0.originalURL) })

        var mergedTrashedIDs = trashedAssetIDs
        let knownTrashedIDs = Set(mergedTrashedIDs)
        mergedTrashedIDs.append(contentsOf: previous.trashedAssetIDs.filter { !knownTrashedIDs.contains($0) })

        var mergedStagedIDs = stagedAssetIDs
        let knownStagedIDs = Set(mergedStagedIDs)
        mergedStagedIDs.append(contentsOf: previous.stagedAssetIDs.filter { !knownStagedIDs.contains($0) })

        return DeletionReceipt(
            trashedAssetIDs: mergedTrashedIDs,
            trashedFiles: mergedFiles,
            stagedAssetIDs: mergedStagedIDs,
            failedCount: failedCount,
            firstFailureDescription: firstFailureDescription
        )
    }
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
            let result = trashFiles(urls, folderScope: folderScope)
            return DeletionReceipt(
                trashedAssetIDs: assets.map(\.localIdentifier),
                trashedFiles: result.trashed,
                stagedAssetIDs: [],
                failedCount: result.failures.count,
                firstFailureDescription: result.failures.first?.localizedDescription
            )

        case .holdForReview:
            // Add assets to the review album; do not delete. File URLs still go
            // to Trash — there's no equivalent staging concept for disk files.
            if !assets.isEmpty {
                try await addToReviewAlbum(assets)
            }
            let result = trashFiles(urls, folderScope: folderScope)
            return DeletionReceipt(
                trashedAssetIDs: [],
                trashedFiles: result.trashed,
                stagedAssetIDs: assets.map(\.localIdentifier),
                failedCount: result.failures.count,
                firstFailureDescription: result.failures.first?.localizedDescription
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
    ///
    /// Attempts every URL even when some fail, so files already moved to the
    /// Trash are never silently unreported: successes carry their Trash
    /// destination (for undo) and failures are collected for the caller to
    /// surface as a partial-failure message.
    private static func trashFiles(_ urls: [URL], folderScope: URL?) -> (trashed: [TrashedFile], failures: [Error]) {
        guard !urls.isEmpty else { return ([], []) }
        let scoped = folderScope?.startAccessingSecurityScopedResource() ?? false
        defer { if scoped { folderScope?.stopAccessingSecurityScopedResource() } }

        var trashed: [TrashedFile] = []
        var failures: [Error] = []
        for url in urls {
            // Already-gone originals are vacuous successes, not failures.
            // After a partial failure the ViewModel keeps the whole group for
            // retry, so the retry re-submits items whose files the first
            // attempt DID trash. Re-attempting `trashFile` on those would
            // throw `trashFailed`, inflating `failedCount` (the group could
            // then never be removed) — so skip them silently. No TrashedFile
            // entry is emitted either: this attempt moved nothing, and the
            // attempt that actually trashed the file already holds the undo
            // handle in its own receipt.
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let destination = try trashFile(url)
                trashed.append(TrashedFile(originalURL: url, trashedURL: destination))
            } catch {
                failures.append(error)
            }
        }
        return (trashed, failures)
    }

    /// Moves one file to the Trash and returns where it landed.
    private static func trashFile(_ url: URL) throws -> URL {
#if os(macOS)
        // Best-effort per-child scope: a child URL enumerated under a
        // security-scoped folder has no bookmark of its own, so this often
        // returns false even when access is valid via the parent scope held by
        // `trashFiles`. Don't hard-fail on it — let `trashItem` be the arbiter.
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            // trashItem always populates the out-param on success; the fallback
            // keeps undo safely best-effort (the original no longer exists, so
            // a restore attempt would just be skipped).
            return (resultingURL as URL?) ?? url
        } catch {
            throw DeleteError.trashFailed(url, error)
        }
#else
        // iOS has no filesystem Trash and no arbitrary folder access;
        // file URL items never reach this code path in production.
        throw DeleteError.accessDenied
#endif
    }

    /// Moves previously trashed files back to their original locations,
    /// holding the folder's security scope open like `trashFiles` does.
    ///
    /// Best-effort per file: entries whose Trash URL no longer exists (the
    /// user emptied the Trash) or whose original path is now occupied are
    /// skipped. Returns the entries that were actually restored so the caller
    /// can mark the matching audit-log records.
    static func restoreTrashedFiles(_ files: [TrashedFile], folderScope: URL?) -> [TrashedFile] {
        guard !files.isEmpty else { return [] }
        let scoped = folderScope?.startAccessingSecurityScopedResource() ?? false
        defer { if scoped { folderScope?.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        var restored: [TrashedFile] = []
        for file in files {
            guard fm.fileExists(atPath: file.trashedURL.path),
                  !fm.fileExists(atPath: file.originalURL.path) else { continue }
            do {
                try fm.moveItem(at: file.trashedURL, to: file.originalURL)
                restored.append(file)
            } catch {
                continue  // best-effort: leave the file in the Trash
            }
        }
        return restored
    }
}
