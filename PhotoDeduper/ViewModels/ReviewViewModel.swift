import Foundation
import Photos
import SwiftUI

// MARK: - Model

struct PhotoGroup: Identifiable {
    let id = UUID()
    var items: [PhotoItem]
    var proposedKeeperIndex: Int
    var scores: [Double]
    var qualities: [PhotoQuality]
    /// On-device close-call resolution explanation (Vision-based, fully on-device).
    var localExplanation: String?
    var isCloseCall: Bool
    var keptIndices: Set<Int> = []

    /// Origin label so the sidebar can hint whether a group came from a burst,
    /// a time window, or a video match.
    var origin: GroupOrigin = .timeWindow

    /// The lowest kept index; used for the sidebar thumbnail and lightbox status label.
    var primaryKeeperIndex: Int { keptIndices.min() ?? proposedKeeperIndex }

    /// Raw quality scores for display; the scorer's sigmoid normalization already
    /// provides meaningful spread, so no artificial stretching is applied here.
    var displayScores: [Double] { scores }

    var itemsToDelete: [PhotoItem] {
        items.enumerated().compactMap { i, item in keptIndices.contains(i) ? nil : item }
    }

    var itemsToKeep: [PhotoItem] {
        items.enumerated().compactMap { i, item in keptIndices.contains(i) ? item : nil }
    }

    /// True iff at least one item in the group is protected (favorite / in
    /// protected album). The UI uses this to show a lock icon and prevent
    /// accidental deletion.
    var containsProtected: Bool { items.contains { $0.isProtected } }
}

enum GroupOrigin: String {
    case timeWindow
    case burst
    case video
}

enum ScanState {
    case idle
    case scanning(progress: Double, message: String, phase: ScanPhase = .preparing, etaSeconds: Double? = nil)
    case reviewing
    case done(keptCount: Int, deletedCount: Int, freedBytes: Int64)
    case error(String)
}

enum ScanPhase: String {
    case preparing      = "Preparing"
    case fetching       = "Fetching"
    case timeGrouping   = "Time grouping"
    case visualVerify   = "Visual verification"
    case videoMatching  = "Video matching"
    case scoring        = "Quality scoring"
    case finalising     = "Finalising"
}

// MARK: - ViewModel

@MainActor
final class ReviewViewModel: ObservableObject {
    @Published var groups: [PhotoGroup] = []
    /// Groups the user has set aside for deletion ("mark, then flush").
    /// Staging is a pure local state move — nothing touches PhotoKit or the
    /// file system until `confirmDelete()` flushes everything in one request.
    /// Kept separate from `groups` (rather than a flag on PhotoGroup) so the
    /// sidebar/detail views keep iterating `groups` unchanged and the staged
    /// set can be restored wholesale.
    @Published private(set) var stagedGroups: [PhotoGroup] = []
    @Published var selectedGroupID: UUID?
    @Published var scanState: ScanState = .idle
    @Published var showConfirmDelete = false
    @Published var faceToFaceGroupID: UUID?
    @Published var lastReceipt: DeletionReceipt?
    @Published var undoBannerExpiresAt: Date?
    /// Short-lived, non-blocking status line (partial deletion failures, undo
    /// shortfalls). Auto-cleared by `showTransientNotice` after a few seconds,
    /// mirroring the undo banner's expiry handling — these outcomes matter but
    /// shouldn't hijack the whole window the way `scanState = .error` does.
    @Published var transientNotice: String?
    /// How many items the last `confirmDelete` failed to remove. Stashed here
    /// (rather than widening `ScanState.done`, which would ripple through
    /// ContentView's pattern matches) so DoneView can show a warning line next
    /// to its stats. Cleared by `reset()`.
    @Published private(set) var lastDeleteFailedCount: Int = 0

    /// Drives the in-review "Settings changed — they apply to a new scan"
    /// banner. The scan-affecting settings (timeWindow, pHashThreshold,
    /// closeCallThreshold, scanVideosToo, protectedAlbumIDs) are read ONCE at
    /// the top of `runPipeline`, so editing them mid-review changes nothing on
    /// screen — users reported tweaking the sliders and assuming the app was
    /// broken. ReviewView snapshots those values before opening Settings and,
    /// on dismissal, flips this true if any changed, prompting an offer to
    /// rescan. Reset by `rescan()` (it re-runs with the new values) and the
    /// banner's "X" dismiss; also cleared by `reset()` so a fresh session
    /// never inherits a stale prompt.
    @Published var pendingRescan = false

    /// The currently running scan task, if any. Held so the user can cancel mid-scan.
    private var currentScanTask: Task<Void, Never>?

    /// A closure that re-invokes the SAME scan entry point the current results
    /// came from, with the SAME argument (album / folder URL / picked IDs).
    /// Captured at the top of each entry point so `rescan()` can replay the
    /// exact scan after the user changes settings mid-review — without
    /// ReviewView having to know which of the four scan modes produced the
    /// current groups. Plain library scans capture a no-arg closure; the album
    /// and picked-photos scans close over their argument; the folder scan could
    /// read `scannedFolderURL`, but it captures `url` too so every entry point
    /// follows the same one-line pattern.
    private var lastScanAction: (() -> Void)?
    private var scanStartTime: Date? {
        didSet { etaSamples.removeAll() }
    }
    /// Circular buffer of (elapsed seconds, progress) samples used by `computeETA`.
    /// Cleared automatically whenever `scanStartTime` is reset (new scan start or cancel).
    private var etaSamples: [(elapsed: Double, progress: Double)] = []
    /// Count of individual photos scored so far in the current scan's scoring
    /// phase. Drives item-level scoring progress so a single large group doesn't
    /// freeze the bar. Reset to 0 at the start of the scoring loop.
    private var scoredItemCount = 0
    /// Task that clears the undo banner once its 30-second window elapses.
    /// SwiftUI doesn't re-evaluate `hasActiveUndo` on its own; a timer is
    /// required to nil out `undoBannerExpiresAt` and trigger a view update.
    private var undoExpiryTask: Task<Void, Never>?
    /// Task that clears `transientNotice` at the end of its display window —
    /// same rationale as `undoExpiryTask`: nothing else would trigger the
    /// view update that hides the notice.
    private var transientNoticeTask: Task<Void, Never>?
    let sessionStart = Date()

    /// Asset IDs the user has marked as belonging to protected albums.
    /// Read from UserDefaults at scan time; favourited items are auto-protected.
    private var protectedAssetIDs: Set<String> = []

    /// The security-scoped folder URL the current results came from (folder scans
    /// only; nil for Photos-library scans). Retained so its access scope can be
    /// re-opened when trashing the folder's files at delete time — child file URLs
    /// carry no bookmark of their own.
    private var scannedFolderURL: URL?

    /// Re-entry guard against double-delete. Set on entry to confirmDelete and
    /// cleared on every exit path so a second rapid tap (e.g. double-tap on
    /// the delete button) can't kick off a concurrent deletion of the same items.
    private var isDeleting = false

    // Both aggregates span `groups` AND `stagedGroups`: the toolbar's
    // "Delete N Photos" flush deletes everything from both collections, so the
    // count/bytes it advertises must match what the flush will actually do.
    var totalToDelete: Int {
        (groups + stagedGroups).reduce(0) { $0 + $1.itemsToDelete.count }
    }

    var estimatedFreedBytes: Int64 {
        (groups + stagedGroups).flatMap(\.itemsToDelete).reduce(Int64(0)) { $0 + $1.estimatedByteSize }
    }

    var hasActiveUndo: Bool {
        guard let expiry = undoBannerExpiresAt else { return false }
        return expiry > Date()
    }

    /// Whether the last delete is still recoverable, independent of the
    /// in-review banner's countdown. `hasActiveUndo` expires with the banner
    /// timer; this stays true as long as a receipt exists — files are still in
    /// the Trash and assets in Recently Deleted (both 30 days). DoneView gates
    /// its Undo button on THIS, not `hasActiveUndo`, so a user sitting on the
    /// success screen can always undo without a hidden timer yanking the button
    /// away. Cleared only by `attemptUndo` (consumes the receipt) and `reset()`.
    var canUndoLastDelete: Bool { lastReceipt != nil }

    /// True when the current results came from a folder scan, where deletion
    /// means the macOS Trash rather than Photos' Recently Deleted. Views use
    /// this to pick the right confirmation/done copy.
    var isFolderScan: Bool { scannedFolderURL != nil }

    /// True when the last deletion moved files to the macOS Trash, so undo can
    /// genuinely put them back (vs. just opening Photos for library assets).
    var lastReceiptHasFileDeletions: Bool {
        !(lastReceipt?.trashedFiles.isEmpty ?? true)
    }

    /// Platform-specific message shown when full-library Photos authorization is denied.
    private var photosAccessDeniedMessage: String {
#if os(macOS)
        "Photo library access is required. Grant access in System Settings → Privacy & Security → Photos."
#else
        "Photo library access is required. Open Settings → Privacy → Photos and grant access."
#endif
    }

    // MARK: - Entry points

    func startScan() {
        cancelScan()
        // Capture this exact invocation so `rescan()` can replay it verbatim
        // after a mid-review settings change. No argument to retain — a full
        // library scan re-runs by just calling itself.
        lastScanAction = { [weak self] in self?.startScan() }
        currentScanTask = Task { [weak self] in
            guard let self else { return }
            self.scanStartTime = Date()
            let lib = PhotoLibraryManager()
            guard await lib.requestAuthorization() else {
                if Task.isCancelled { return }
                self.scanState = .error(self.photosAccessDeniedMessage)
                return
            }
            if Task.isCancelled { return }
            await self.refreshProtectedAssetIDs(library: lib)
            self.publishScanState(progress: 0.05, message: "Fetching photos…", phase: .fetching)

            let filter: PhotoLibraryManager.MediaFilter = AppDefaults.scanVideosToo ? .stillsAndVideos : .stillsOnly
            let items = await lib.fetchAllPhotos(filter: filter)
            if Task.isCancelled { return }
            await self.runPipeline(items)
        }
    }

    func startAlbumScan(album: PhotoAlbum) {
        cancelScan()
        // Close over `album` so `rescan()` re-scans the SAME album, not the
        // whole library — replaying the user's actual scope.
        lastScanAction = { [weak self] in self?.startAlbumScan(album: album) }
        currentScanTask = Task { [weak self] in
            guard let self else { return }
            self.scanStartTime = Date()
            let lib = PhotoLibraryManager()
            guard await lib.requestAuthorization() else {
                if Task.isCancelled { return }
                self.scanState = .error(self.photosAccessDeniedMessage)
                return
            }
            if Task.isCancelled { return }
            await self.refreshProtectedAssetIDs(library: lib)
            self.publishScanState(progress: 0.05, message: "Loading \(album.title)…", phase: .fetching)

            let filter: PhotoLibraryManager.MediaFilter = AppDefaults.scanVideosToo ? .stillsAndVideos : .stillsOnly
            let items = await lib.fetchPhotos(from: album.collection, filter: filter)
            if Task.isCancelled { return }
            await self.runPipeline(items)
        }
    }

    /// Scans a hand-picked set of photos identified by their PHAsset local identifiers.
    ///
    /// The identifiers are supplied by `LibraryPhotoPicker`, which uses
    /// `PHPickerConfiguration(photoLibrary:)` — the *library-backed* picker.
    /// That configuration always populates `PHPickerResult.assetIdentifier`,
    /// even when the user has only "Limited" Photos access (the picker just
    /// restricts which photos the user can see).
    ///
    /// Strategy:
    /// 1. Verify Photos authorization is still in place (the view already
    ///    requested it before showing the picker, but we double-check).
    /// 2. Resolve identifiers → `PHAsset` objects via
    ///    `PHAsset.fetchAssets(withLocalIdentifiers:)`.
    /// 3. If we got any assets back, run the dedup pipeline on them.
    /// 4. If we got zero assets back, surface a clear actionable error
    ///    rather than silently scanning temporary copies — copies would
    ///    mislead the user into thinking "Delete" removes the originals.
    func startPickedPhotosScan(identifiers: [String]) {
        cancelScan()
        guard !identifiers.isEmpty else { return }
        // Close over the picked `identifiers` so `rescan()` re-resolves and
        // re-scans the same hand-picked set rather than the whole library.
        lastScanAction = { [weak self] in self?.startPickedPhotosScan(identifiers: identifiers) }
        currentScanTask = Task { [weak self] in
            guard let self else { return }
            self.scanStartTime = Date()
            self.publishScanState(
                progress: 0.02,
                message: "Loading \(identifiers.count) selected photo\(identifiers.count == 1 ? "" : "s")…",
                phase: .fetching
            )

            let lib = PhotoLibraryManager()
            let hasAuth = await lib.requestAuthorization()
            if Task.isCancelled { return }

            guard hasAuth else {
#if os(macOS)
                self.scanState = .error("DeDuper needs Photos library access to scan selected photos. Open System Settings → Privacy & Security → Photos and grant access, then try again.")
#else
                self.scanState = .error("DeDuper needs Photos library access to scan selected photos. Open Settings → Privacy → Photos and grant access, then try again.")
#endif
                return
            }

            await self.refreshProtectedAssetIDs(library: lib)

            var resolvedItems: [PhotoItem] = []
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            fetch.enumerateObjects { asset, _, _ in resolvedItems.append(PhotoItem.from(asset)) }

            if Task.isCancelled { return }
            guard !resolvedItems.isEmpty else {
                // Identifiers came from the library-backed picker so they
                // should always resolve.  If they don't it's most likely
                // because the photos live in a Shared Library or a People
                // album that isn't part of the user's personal library.
                // Name the likely cause AND give two concrete escape routes:
                // an owned album (still a Photos scan) or a Mac folder (file
                // scan, sidesteps PhotoKit entirely) — both bypass the
                // unresolvable-identifier case above.
                self.scanState = .error("Couldn't read the selected photos. Some photos (e.g. from a Shared Library) can't be scanned this way — try \"Choose Album…\" for an album you own, or \"Choose Folder…\" for files on your Mac.")
                return
            }

            await self.runPipeline(resolvedItems)
        }
    }

    func startFolderScan(url: URL) {
        cancelScan()
        scannedFolderURL = url
        // Close over `url` so `rescan()` re-scans the SAME folder. (`cancelScan`
        // inside the replayed call nils `scannedFolderURL`, but the very next
        // line here re-sets it from the captured `url`, so the security-scoped
        // scope is restored — no need to read the cleared property.)
        lastScanAction = { [weak self] in self?.startFolderScan(url: url) }
        currentScanTask = Task { [weak self] in
            guard let self else { return }
            self.scanStartTime = Date()
            self.publishScanState(progress: 0.02, message: "Reading folder…", phase: .fetching)
            let lib = PhotoLibraryManager()
            let filter: PhotoLibraryManager.MediaFilter = AppDefaults.scanVideosToo ? .stillsAndVideos : .stillsOnly
            let items = await lib.scanFolder(url, filter: filter)
            if Task.isCancelled { return }
            guard !items.isEmpty else {
                // Lists the formats DeDuper actually scans so the user can tell
                // at a glance whether the empty result is "wrong folder" vs
                // "unsupported files". The set MUST track PhotoItem.imageExtensions
                // (jpg/jpeg, png, heic/heif, tiff, and common RAW: cr2/cr3, nef,
                // arw, dng, raf, orf, rw2) — note GIF is NOT in that set, so it is
                // deliberately absent here. If imageExtensions changes, change this.
                self.scanState = .error("No supported images found. DeDuper scans JPEG, PNG, HEIC/HEIF, TIFF, and common RAW files — check that the folder contains those.")
                return
            }
            await self.runPipeline(items)
        }
    }

    /// Cancels any in-progress scan/scoring and returns the app to the idle state.
    /// Safe to call when no scan is running.
    func cancelScan() {
        currentScanTask?.cancel()
        currentScanTask = nil
        // Cleared on every scan start (each entry point calls cancelScan first);
        // startFolderScan re-sets it immediately after. Photos-library scans
        // leave it nil so no folder scope is held when trashing assets.
        scannedFolderURL = nil
        if case .scanning = scanState {
            scanState = .idle
            // Clear partially-scored clusters so a cancelled scan doesn't leave
            // stale groups in the published array (matches runPipeline's start).
            groups = []
            stagedGroups = []
            selectedGroupID = nil
        }
    }

    // MARK: - Shared pipeline

    private func runPipeline(_ items: [PhotoItem]) async {
        groups = []
        // A new scan invalidates anything staged from the previous results —
        // those PhotoGroups reference old scan items and must never survive
        // into the next session's flush.
        stagedGroups = []
        selectedGroupID = nil

        guard !items.isEmpty else {
            scanState = .reviewing
            return
        }

        let timeWindow        = AppDefaults.timeWindow
        let hashThreshold     = AppDefaults.pHashThreshold
        let closeCallFraction = AppDefaults.closeCallThreshold / 100.0
        /// Sharpness veto threshold, applied in RAW edge-energy space (the
        /// sigmoid-compressed `PhotoQuality.sharpness` is inverted first — see
        /// `rawSharpness` in the scoring loop): a proposed keeper must have at
        /// least this fraction of its group's max raw sharpness, or the keeper
        /// slot moves to the best-scoring copy that does. Calibrated against
        /// measured values: at the 512px scoring size a mildly blurred copy
        /// (2.2px Gaussian at 1600px) lands at raw ratio ~0.81 vs its sharp
        /// original — real blur the aesthetics model's 0.40 weight in `total`
        /// can out-vote — while re-encodes of identical content sit at ~0.95+.
        /// 0.85 splits those; if real-library burst shots ever get vetoed
        /// spuriously, this is the knob to loosen.
        let sharpnessVetoFactor = 0.85

        // Augment items with protected-album info before the pipeline starts.
        let augmented = applyProtectedFlags(items)

        // 1) Split stills from videos — they run through different verifiers.
        let stills = augmented.filter { !$0.isVideo }
        let videos = augmented.filter { $0.isVideo }

        // 2) Time + burst grouping for stills.
        if Task.isCancelled { return }
        publishScanState(progress: 0.08, message: "Finding time-adjacent groups…", phase: .timeGrouping)
        let grouper = SimilarityGrouper()
        let (burstRaw, timeRaw) = grouper.groupByTime(stills, windowSeconds: timeWindow)

        if Task.isCancelled { return }
        var verifiedBurst: [[PhotoItem]] = []
        var verifiedTime: [[PhotoItem]] = []
        if !burstRaw.isEmpty {
            verifiedBurst = await grouper.verifyVisualSimilarity(burstRaw, threshold: hashThreshold) { [weak self] p in
                Task { @MainActor [weak self] in
                    self?.publishScanState(progress: 0.10 + p * 0.15, message: "Verifying visual similarity…", phase: .visualVerify)
                }
            }
        }
        if Task.isCancelled { return }
        if !timeRaw.isEmpty {
            verifiedTime = await grouper.verifyVisualSimilarity(timeRaw, threshold: hashThreshold) { [weak self] p in
                Task { @MainActor [weak self] in
                    self?.publishScanState(progress: 0.25 + p * 0.15, message: "Verifying visual similarity…", phase: .visualVerify)
                }
            }
        }

        if Task.isCancelled { return }

        // 3) Video duplicate detection.
        var videoGroups: [[PhotoItem]] = []
        if !videos.isEmpty {
            publishScanState(progress: 0.52, message: "Matching videos…", phase: .videoMatching)
            videoGroups = await findVideoDuplicates(videos) { [weak self] p in
                Task { @MainActor [weak self] in
                    self?.publishScanState(progress: 0.52 + p * 0.10, message: "Matching videos…", phase: .videoMatching)
                }
            }
        }

        if Task.isCancelled { return }
        let allGroups = verifiedBurst.map { ($0, GroupOrigin.burst) }
            + verifiedTime.map { ($0, GroupOrigin.timeWindow) }
            + videoGroups.map { ($0, GroupOrigin.video) }
        guard !allGroups.isEmpty else { scanState = .reviewing; return }

        // 4) Scoring. Stream results into `groups` as each cluster is scored so
        // the user sees groups appear progressively (the chunked-scan UX).
        let scorer = PhotoScorer()
        groups = []
        // Drive the scoring progress band off items scored (not groups completed)
        // so a single large group still advances the bar instead of looking frozen.
        let totalItemsToScore = allGroups.reduce(0) { $0 + $1.0.count }
        scoredItemCount = 0
        for (group, origin) in allGroups {
            if Task.isCancelled { return }
            let qualities = await scorer.evaluateGroup(group) { [weak self] in
                Task { @MainActor in self?.bumpScoringProgress(total: totalItemsToScore) }
            }
            let scores = qualities.map(\.total)
            if Task.isCancelled { return }
            let sorted = scores.indices.sorted { scores[$0] > scores[$1] }
            var best = sorted.first ?? 0
            var localExplanation: String?

            // Sharpness veto. For faceless photos `total` weights aesthetics at
            // 0.40 (PhotoScorer), and the Vision aesthetics model sometimes
            // prefers a smoother/blurred copy — enough to out-vote a real
            // sharpness gap and propose deleting the sharp original. If the
            // score-winner is materially blurrier than the sharpest copy, hand
            // the keeper slot to the best-`total` candidate that is acceptably
            // sharp. Skipped for single-item groups and when maxSharp ≈ 0
            // (all-blurry/undecodable group — no meaningful sharpness signal,
            // and it avoids degenerate near-zero comparisons).
            // Ordering: this runs BEFORE protected promotion (explicit user
            // signal beats this heuristic) and before the close-call resolver,
            // which may still override the veto'd pick — acceptable, since that
            // resolver only fires on a clear face-quality signal on both
            // candidates, a stronger cue than raw sharpness.
            // PhotoQuality.sharpness is sigmoid-compressed (raw/(raw+0.5) in
            // PhotoScorer), and the curve flattens near 1.0: a 45% raw
            // edge-energy gap (genuinely blurry vs sharp) can land at 0.88 vs
            // 0.93 — a 0.95 ratio that sails past the veto (verified live on
            // synthetic near-dups). Invert back to raw space so the ratio test
            // measures the real gap. The inverse is monotonic, so ordering is
            // preserved; the 0.5 sigmoid scale cancels out of the ratio.
            func rawSharpness(_ s: Double) -> Double {
                s >= 0.9999 ? .infinity : s / (1 - s)
            }
            let maxSharp = qualities.map(\.sharpness).max() ?? 0
            let rawMax = rawSharpness(maxSharp)
            if group.count >= 2, maxSharp > 0.0001, rawMax.isFinite,
               rawSharpness(qualities[best].sharpness) < rawMax * sharpnessVetoFactor {
                // `sorted` is descending by total, so the first survivor of the
                // sharpness filter is the best-scoring acceptably-sharp copy.
                if let sharpBest = sorted.first(where: {
                    rawSharpness(qualities[$0].sharpness) >= rawMax * sharpnessVetoFactor
                }) {
                    best = sharpBest
                    // Surfaced as "Why this one?" in the UI. The close-call
                    // resolver below may overwrite this when it fires — fine,
                    // its face-based reason describes the final pick better.
                    localExplanation = "Kept the sharper copy"
                }
            }

            // Promote any protected item to proposed keeper. Track whether a
            // promotion occurred — if it did, skip local close-call resolution
            // so a heuristic winner can't override the user's explicit signal.
            // Indices of every protected item. The lowest doubles as the
            // promotion target (matching the old `firstIndex`); the whole set is
            // re-applied as keepers wherever `kept` is (re)built below.
            let protectedKeepers = Set(group.indices.filter { group[$0].isProtected })
            let protectedIdx = protectedKeepers.min()
            if let idx = protectedIdx {
                best = idx
                // Promotion discards the veto's pick, so its explanation no
                // longer describes the keeper — drop it rather than mislead.
                localExplanation = nil
            }

            var isCloseCall = false
            if sorted.count > 1 {
                // Use natural ranking scores (sorted[0]/[1]), not scores[best].
                // best may have been overridden to a low-scoring protected item;
                // using scores[best] there makes (top - second) negative → always a close call.
                let top = scores[sorted[0]], second = scores[sorted[1]]
                isCloseCall = top > 0 && (top - second) / max(top, 0.0001) < closeCallFraction
            }

            // Mark all protected items as keepers; otherwise just the best.
            var kept: Set<Int> = [best]
            kept.formUnion(protectedKeepers)

            // On-device close-call resolution — skipped when a protected item was
            // explicitly promoted, so its proposedKeeperIndex stays correct.
            // (Declared above so the sharpness veto can also explain its pick.)
            if isCloseCall && protectedIdx == nil {
                if let (winnerIdx, reason) = resolveCloseCallLocally(qualities: qualities, ranked: sorted) {
                    best = winnerIdx
                    // protectedIdx == nil here ⟹ protectedKeepers is empty, so
                    // `best` is the sole keeper — nothing to re-union.
                    kept = [best]
                    localExplanation = reason
                }
            }

            // Never auto-delete an item we couldn't decode/assess (corrupt file,
            // or an iCloud asset not downloaded at scan time). Force it into the
            // keepers so itemsToDelete can never include it — a 0 score otherwise
            // makes it the proposed deletion, the inverse of safe.
            for (idx, q) in qualities.enumerated() where q.isUndecodable { kept.insert(idx) }

            var photoGroup = PhotoGroup(
                items: group,
                proposedKeeperIndex: best,
                scores: scores,
                qualities: qualities,
                localExplanation: localExplanation,
                isCloseCall: isCloseCall,
                keptIndices: kept
            )
            photoGroup.origin = origin
            groups.append(photoGroup)
            if selectedGroupID == nil { selectedGroupID = photoGroup.id }
        }

        if Task.isCancelled { return }
        // Warm the review-grid thumbnail cache and kick off iCloud prefetch ONCE,
        // after scoring — not per group. Calling these inside the loop with the
        // whole accumulated `groups` array was O(N²) main-thread churn and flooded
        // PHImageManager.default() with network downloads that starved the scorer's
        // own thumbnail loads — the cause of the mid-scan stall.
        ThumbnailCache.shared.warmup(for: groups)
        ThumbnailCache.shared.prefetchICloudAssets(for: groups)

        publishScanState(progress: 0.98, message: "Finishing up…", phase: .finalising)
        scanState = .reviewing
        currentScanTask = nil
    }

    // MARK: - User actions

    /// Indices that must always remain keepers in a group, regardless of which
    /// photo is chosen: protected items (favorites) and undecodable items (whose
    /// pixels couldn't be assessed — never auto-delete). `selectKeeper` rebuilds
    /// keptIndices from scratch and must re-apply these, otherwise an undecodable
    /// item silently falls into the deletion set.
    private func mandatoryKeepers(in group: PhotoGroup) -> Set<Int> {
        var indices = Set<Int>()
        for (idx, item) in group.items.enumerated() where item.isProtected { indices.insert(idx) }
        for (idx, q) in group.qualities.enumerated() where q.isUndecodable { indices.insert(idx) }
        return indices
    }

    func toggleKeep(groupID: UUID, itemIndex: Int) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        // Hardening: reject out-of-bounds indices outright. Previously an OOB
        // index skipped the protected check below and was inserted into
        // keptIndices anyway. (No current caller passes one.)
        guard groups[i].items.indices.contains(itemIndex) else { return }
        // Protected items and undecodable items (which must never be auto-deleted)
        // cannot be marked for deletion via this toggle.
        if groups[i].items[itemIndex].isProtected || groups[i].qualities[itemIndex].isUndecodable {
            return
        }
        if groups[i].keptIndices.contains(itemIndex) {
            groups[i].keptIndices.remove(itemIndex)
        } else {
            groups[i].keptIndices.insert(itemIndex)
        }
    }

    func selectKeeper(groupID: UUID, itemIndex: Int) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        var kept: Set<Int> = [itemIndex]
        kept.formUnion(mandatoryKeepers(in: groups[i]))
        groups[i].keptIndices = kept
    }

    func selectNextGroup()     { selectGroup(offset: 1) }
    func selectPreviousGroup() { selectGroup(offset: -1) }

    private func selectGroup(offset: Int) {
        guard let id = selectedGroupID,
              let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        let target = idx + offset
        guard groups.indices.contains(target) else { return }
        // Defer the @Published mutation: onKeyPress handlers can fire while
        // SwiftUI is mid view-update, and a synchronous assignment here trips
        // "Publishing changes from within view updates".
        let nextID = groups[target].id
        DispatchQueue.main.async { [weak self] in
            self?.selectedGroupID = nextID
        }
    }

    /// Stages a group for deletion — a pure local state move, no PhotoKit or
    /// file I/O.
    ///
    /// Why staging exists: deleting Photos-library assets triggers an
    /// unavoidable macOS system prompt ("Allow PhotoDeduper to delete N
    /// photos?") PER PhotoKit request. When the per-group action fired its own
    /// delete request, a 40-group review session meant 40 prompts. Staging
    /// makes the per-group action instant and prompt-free; the toolbar's
    /// single "Delete N Photos" flush (`confirmDelete`) then removes
    /// everything in ONE PhotoKit request — one system prompt per session.
    func stageGroup(groupID: UUID) {
        // Defer the @Published mutations to a fresh runloop tick: this is
        // reachable from an onKeyPress handler (`d`), which can fire while
        // SwiftUI is mid view-update — a synchronous write here trips
        // "Publishing changes from within view updates" (same rationale as
        // `selectGroup(offset:)`). The groupID lookup also happens inside the
        // block so a double-tap of `d` finds the group already gone and no-ops.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // A stage block enqueued just before a flush completes could drain
            // after `confirmDelete` already cleared both collections — ignore
            // it once the session has left review, so a deleted group can't be
            // resurrected into `stagedGroups` as a stale ghost.
            guard case .reviewing = self.scanState else { return }
            guard let idx = self.groups.firstIndex(where: { $0.id == groupID }) else { return }
            // Reassign selection BEFORE removing the group (next, else
            // previous, else nil) so the sidebar List's two-way binding never
            // observes a missing selected ID.
            if self.groups[idx].id == self.selectedGroupID {
                if idx + 1 < self.groups.count {
                    self.selectedGroupID = self.groups[idx + 1].id
                } else if idx > 0 {
                    self.selectedGroupID = self.groups[idx - 1].id
                } else {
                    self.selectedGroupID = nil
                }
            }
            self.stagedGroups.append(self.groups.remove(at: idx))
        }
    }

    /// Stages EVERY remaining live group in one shot (the toolbar "Set Aside
    /// All" action) — the bulk counterpart to per-group `stageGroup`. For a
    /// user who trusts the proposed keepers across many groups, walking them
    /// one `d` at a time is pure friction; this empties the live list into
    /// `stagedGroups` so they can flush the whole session with a single
    /// "Delete N Photos". Still a pure local state move: like `stageGroup`,
    /// nothing touches PhotoKit or the file system until `confirmDelete`.
    func stageAllGroups() {
        // No live groups ⟹ nothing to stage. Guard up front so the deferred
        // block below can't fire a redundant @Published write (which would
        // still publish and nudge SwiftUI) on an already-empty list.
        guard !groups.isEmpty else { return }
        // Defer the @Published mutations to a fresh runloop tick, exactly as
        // `stageGroup`/`selectGroup(offset:)` do: this is reachable from a
        // toolbar button during a view update, and a synchronous write trips
        // "Publishing changes from within view updates". Re-checking inside the
        // block also makes a double-invocation (rapid double-click) find the
        // groups already drained and no-op.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Same late-flush guard as `stageGroup`: a stage-all enqueued just
            // before a flush completes must not resurrect groups into
            // `stagedGroups` after `confirmDelete` already cleared everything.
            guard case .reviewing = self.scanState else { return }
            guard !self.groups.isEmpty else { return }
            // No live groups remain selectable once the list is emptied, so
            // clear the selection (the sidebar List binding would otherwise
            // point at a now-missing ID) — mirrors the nil-selection branch in
            // `stageGroup`.
            self.selectedGroupID = nil
            self.stagedGroups.append(contentsOf: self.groups)
            self.groups = []
        }
    }

    /// Moves every staged group back into the live review list (the sidebar's
    /// "Restore" action). Appending at the end is deliberate: the user already
    /// reviewed past these groups, so they shouldn't displace the current
    /// position in the list.
    func restoreStagedGroups() {
        guard !stagedGroups.isEmpty else { return }
        let restored = stagedGroups
        stagedGroups = []
        groups.append(contentsOf: restored)
        // Only adopt a selection when there is none (every live group was
        // staged); otherwise leave the user's current position alone.
        if selectedGroupID == nil { selectedGroupID = restored.first?.id }
    }

    /// Re-runs the SAME scan the current results came from, so a mid-review
    /// settings change actually takes effect. Triggered by the "Rescan" button
    /// on the `pendingRescan` banner.
    ///
    /// The scan-affecting settings (timeWindow, pHashThreshold,
    /// closeCallThreshold, scanVideosToo, protectedAlbumIDs) are read fresh at
    /// the top of `runPipeline` / each entry point, so simply replaying
    /// `lastScanAction` re-applies whatever the user just saved — no values are
    /// threaded through here. Clearing `pendingRescan` first hides the banner
    /// immediately; the entry point then drives `scanState` through `.scanning`
    /// (ContentView swaps in the progress view), so the stale review results
    /// are torn down by the normal pipeline reset, not by us.
    func rescan() {
        pendingRescan = false
        lastScanAction?()
    }

    func confirmDelete() async {
        guard !isDeleting else { return }
        isDeleting = true
        // confirmDelete is fully awaited inline, so a function-scope defer is
        // safe here — it fires on every exit (success or catch). Placed after
        // the guard so a blocked re-entry can't clear the in-flight call's flag.
        defer { isDeleting = false }
        // Flush staged groups AND the remaining live groups in ONE
        // BatchDeleteManager call — the whole point of the staging model:
        // a single PhotoKit request means a single macOS "Allow PhotoDeduper
        // to delete N photos?" prompt for the entire session, instead of one
        // per group. Kept/deleted counts must span both collections too.
        let flushGroups = groups + stagedGroups
        let toDeleteByGroup = flushGroups.map { ($0, $0.itemsToDelete) }
        let toDelete = toDeleteByGroup.flatMap(\.1)
        let deletedCount = toDelete.count
        let keptCount = flushGroups.reduce(0) { $0 + $1.keptIndices.count }
        let mode: DeletionMode = AppDefaults.holdForReview ? .holdForReview : .directDelete

        do {
            let receipt = try await BatchDeleteManager.deleteItems(toDelete, mode: mode, folderScope: scannedFolderURL)
            if let message = receipt.allFailedMessage {
                // Total failure: nothing was deleted; surface it like a throw.
                scanState = .error(message)
                return
            }
            // Only show the undo banner when something was actually trashed.
            // In holdForReview mode for library scans both are empty — the
            // banner would be misleading (nothing to recover or put back).
            if !receipt.trashedAssetIDs.isEmpty || !receipt.trashedFiles.isEmpty {
                // Merge with any still-active previous receipt so its Trash
                // undo handles survive — see `absorbing`'s doc comment.
                self.lastReceipt = receipt.absorbing(self.hasActiveUndo ? self.lastReceipt : nil)
                // 120s, not 30s: the old window was too short for a user to read
                // the banner and react before it self-hid. The receipt stays
                // actionable far longer (files in Trash / assets in Recently
                // Deleted, both 30 days) — this timer only governs the in-review
                // *banner*; DoneView's Undo button keys off `lastReceipt`
                // directly (see `canUndoLastDelete`) so it never expires here.
                self.scheduleUndoExpiry(seconds: 120)
            }
            // Only audit-log items that actually left the library/disk. The
            // same pass totals the bytes genuinely freed: the up-front
            // `estimatedFreedBytes` counts ALL candidates and would overstate
            // the "Space freed" stat when some files failed to trash. (With
            // zero failures `succeededItems` returns every item, so this sum
            // equals the old estimate.)
            var freedBytes: Int64 = 0
            for (group, items) in toDeleteByGroup {
                let succeeded = succeededItems(items, receipt: receipt)
                if !succeeded.isEmpty { logDeletions(succeeded, in: group) }
                freedBytes += succeeded.reduce(Int64(0)) { $0 + $1.estimatedByteSize }
            }
            // Stash the failure count for DoneView's warning line BEFORE the
            // state flips to .done, so the very first render sees it.
            lastDeleteFailedCount = receipt.failedCount
            // The flush consumed the staged set — clear it even on PARTIAL
            // failure: each staged photo either got deleted or is counted in
            // `failedCount` (surfaced as DoneView's warning line). Resurrecting
            // just the failed photos' staged groups would mean index surgery
            // across PhotoGroup's parallel arrays (items/scores/qualities/
            // keptIndices) for an already-rare partial-trash failure — not
            // worth it. Total failure returns above with both collections
            // intact, as does the catch below.
            stagedGroups = []
            // Count math: items whose files were already gone (trashed by an
            // earlier partial attempt, silently skipped this pass) appear in
            // `deletedCount` but in neither the receipt's successes nor
            // `failedCount` — they're reported as deleted, which is accurate
            // (they ARE off the disk), while `freedBytes` above credits them
            // to the attempt that actually trashed them. `failedCount` never
            // exceeds the files attempted, so this can't go negative.
            scanState = .done(keptCount: keptCount, deletedCount: deletedCount - receipt.failedCount, freedBytes: freedBytes)
        } catch {
            scanState = .error(error.localizedDescription)
        }
    }

    /// Filters `items` down to those the receipt confirms were deleted or
    /// staged. File items use `url.absoluteString` as their PhotoItem id —
    /// the same key `logDeletions` records as `photoID` — so matching is exact.
    ///
    /// Always filters by the receipt's contents, even with zero failures:
    /// `trashFiles` silently skips files whose originals are already gone
    /// (the retry-after-partial-failure case), so "no failures" no longer
    /// implies "every submitted item succeeded". Those skipped items were
    /// audit-logged and byte-counted by the attempt that actually trashed
    /// them; including them again here would double-log and overstate
    /// freed bytes.
    private func succeededItems(_ items: [PhotoItem], receipt: DeletionReceipt) -> [PhotoItem] {
        var ids = Set(receipt.trashedAssetIDs)
        ids.formUnion(receipt.stagedAssetIDs)
        ids.formUnion(receipt.trashedFiles.map { $0.originalURL.absoluteString })
        return items.filter { ids.contains($0.id) }
    }

    /// Undoes the last deletion as far as each source allows.
    ///
    /// - File deletions: moves files back from the Trash to their original
    ///   locations (a true programmatic undo, best-effort per file).
    /// - Library assets: opens Photos to Recently Deleted so the user can
    ///   recover. Apple does not expose a programmatic restore API for
    ///   already-deleted assets, so this part is a navigation shortcut, not a
    ///   true rollback.
    ///
    /// A mixed receipt does both. Restored file groups are NOT re-inserted
    /// into `groups` — the banner state is simply cleared, matching the
    /// existing Photos-assets behaviour.
    func attemptUndo() async {
        guard let receipt = lastReceipt else { return }
        var restoredPhotoIDs: Set<String> = []
        // Track the file-restore outcome: Trash restores genuinely fail when
        // the Trash was emptied or the original path is occupied again, and
        // silently clearing the banner would leave the user believing their
        // files came back.
        let requestedFiles = receipt.trashedFiles.count
        var restoredFiles = 0
        if !receipt.trashedFiles.isEmpty {
            let restored = BatchDeleteManager.restoreTrashedFiles(receipt.trashedFiles, folderScope: scannedFolderURL)
            restoredFiles = restored.count
            restoredPhotoIDs.formUnion(restored.map { $0.originalURL.absoluteString })
        }
        if !receipt.trashedAssetIDs.isEmpty {
            _ = await BatchDeleteManager.restoreFromRecentlyDeleted(assetIDs: receipt.trashedAssetIDs)
            restoredPhotoIDs.formUnion(receipt.trashedAssetIDs)
        }
        var ids: Set<UUID> = []
        for entry in AuditLogger.shared.sessionEntries(since: sessionStart) {
            if restoredPhotoIDs.contains(entry.photoID) { ids.insert(entry.id) }
        }
        if !ids.isEmpty { AuditLogger.shared.markRestored(ids: ids) }
        // Surface restore shortfalls, but clear the banner regardless: the
        // files that didn't come back are gone from the Trash (or blocked at
        // their original path), so offering a retry would be pointless.
        if requestedFiles > 0 {
            if restoredFiles == 0 {
                showTransientNotice("Couldn't restore — files are no longer in the Trash.")
            } else if restoredFiles < requestedFiles {
                showTransientNotice("Restored \(restoredFiles) of \(requestedFiles) files.")
            }
        }
        lastReceipt = nil
        undoBannerExpiresAt = nil
    }

    func dismissUndoBanner() {
        undoBannerExpiresAt = nil
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
    }

    /// Sets the undo banner's expiry and schedules a task to nil it out so the
    /// banner actually disappears at the end of the window. Without this the
    /// banner would only update on the next unrelated state mutation.
    private func scheduleUndoExpiry(seconds: TimeInterval) {
        undoExpiryTask?.cancel()
        self.undoBannerExpiresAt = Date().addingTimeInterval(seconds)
        undoExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Only clear if the same expiry is still in effect (no later delete triggered another window).
                if let expiry = self.undoBannerExpiresAt, expiry <= Date() {
                    self.undoBannerExpiresAt = nil
                }
                self.undoExpiryTask = nil
            }
        }
    }

    /// Shows a short-lived, non-blocking message and schedules its removal —
    /// the `scheduleUndoExpiry` pattern applied to text: SwiftUI won't clear
    /// the notice on its own, so a task nils it out after the window. Showing
    /// a new notice cancels the previous clear task so the fresh message
    /// always gets its full display window.
    private func showTransientNotice(_ message: String, seconds: TimeInterval = 6) {
        transientNoticeTask?.cancel()
        transientNotice = message
        transientNoticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.transientNotice = nil
                self.transientNoticeTask = nil
            }
        }
    }

    /// Clears the transient notice immediately and cancels its pending
    /// auto-clear task — the manual-dismiss counterpart to `dismissUndoBanner`.
    /// Users reported the ~6s auto-clear yanked the message before they finished
    /// reading; the "X" on the notice banner calls this so they can dismiss on
    /// their own time. Cancelling the task matters: otherwise a later fire of
    /// the in-flight `transientNoticeTask` would nil out a *fresh* notice early.
    func dismissTransientNotice() {
        transientNotice = nil
        transientNoticeTask?.cancel()
        transientNoticeTask = nil
    }

    func reset() {
        groups          = []
        stagedGroups    = []
        selectedGroupID = nil
        scanState       = .idle
        lastReceipt     = nil
        undoBannerExpiresAt = nil
        transientNotice = nil
        transientNoticeTask?.cancel()
        transientNoticeTask = nil
        lastDeleteFailedCount = 0
        // Drop any pending "Settings changed" prompt so the next session never
        // inherits a stale rescan offer from the one just torn down.
        pendingRescan = false
        // Forget how to replay the just-finished scan — leaving this set would let
        // a future "repeat last scan" affordance re-scan a scope (album/folder/
        // picked set) the user has mentally left behind, and re-open a stale
        // security-scoped folder URL from the closure rather than a live bookmark.
        lastScanAction = nil
        ThumbnailCache.shared.stopAll()
    }

    // MARK: - Video duplicates

    /// Pulls fingerprints concurrently and links matching videos into groups.
    private func findVideoDuplicates(_ videos: [PhotoItem], progress: @escaping (Double) -> Void) async -> [[PhotoItem]] {
        guard videos.count >= 2 else { return [] }
        let total = Double(videos.count)
        var fingerprints: [VideoFingerprint] = []
        for (i, video) in videos.enumerated() {
            if Task.isCancelled { return [] }
            if let fp = await VideoHasher.fingerprint(for: video) {
                fingerprints.append(fp)
            }
            progress(Double(i + 1) / total)
        }
        let n = fingerprints.count
        guard n >= 2 else { return [] }
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        for a in 0..<n {
            if Task.isCancelled { return [] }
            for b in (a + 1)..<n {
                if VideoHasher.areSimilar(fingerprints[a], fingerprints[b]) {
                    let ra = find(a), rb = find(b)
                    if ra != rb { parent[ra] = rb }
                }
            }
        }
        var buckets: [Int: [PhotoItem]] = [:]
        for i in 0..<n {
            buckets[find(i), default: []].append(fingerprints[i].item)
        }
        return buckets.values.filter { $0.count >= 2 }
    }

    // MARK: - Close-call resolution

    /// Uses face-quality signals to break ties when sharpness/exposure aren't
    /// decisive. Returns the winner index and a human-readable reason, or nil
    /// if local signals don't justify overriding the top-score pick.
    private func resolveCloseCallLocally(qualities: [PhotoQuality], ranked: [Int]) -> (Int, String)? {
        guard ranked.count >= 2 else { return nil }
        let top = ranked[0], second = ranked[1]
        let topQ = qualities[top], secondQ = qualities[second]

        guard topQ.faceCount > 0, secondQ.faceCount > 0 else { return nil }

        // 1) Overall aesthetics — the strongest "this is the better photo" signal
        //    when Vision's whole-image model is available (macOS 15+/iOS 18+).
        if let ta = topQ.aesthetics, let sa = secondQ.aesthetics {
            if sa > ta + 0.08 { return (second, "Overall this is the stronger photo") }
            if ta > sa + 0.08 { return (top, "Overall this is the stronger photo") }
        }
        // 2) Overall face quality (Vision blends sharpness, lighting, expression).
        let topFace = topQ.faceScore ?? 0
        let secondFace = secondQ.faceScore ?? 0
        if secondFace > topFace + 0.1 {
            return (second, "Faces look sharper / better-framed")
        }
        if topFace > secondFace + 0.1 {
            return (top, "Faces look sharper / better-framed")
        }
        // 3) Eyes — secondary tiebreaker now (was the primary check); only a
        //    clear blink difference flips the pick.
        if secondQ.eyesOpen > topQ.eyesOpen + 0.20 {
            return (second, "Eyes are more open in this shot")
        }
        if topQ.eyesOpen > secondQ.eyesOpen + 0.20 {
            return (top, "Eyes are more open in this shot")
        }
        return nil
    }

    // MARK: - Protected items

    /// Refreshes the protected-asset set from UserDefaults.
    private func refreshProtectedAssetIDs(library: PhotoLibraryManager) async {
        let albumIDs = AppDefaults.protectedAlbumIDs
        guard !albumIDs.isEmpty else { protectedAssetIDs = []; return }
        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: albumIDs, options: nil)
        var found: [PHAssetCollection] = []
        collections.enumerateObjects { col, _, _ in found.append(col) }
        protectedAssetIDs = library.assetIDs(in: found)
    }

    /// Returns `items` with `isProtected` overlaid for anything whose asset ID
    /// is in a protected album. Favourites are already protected via the
    /// PhotoItem initializer.
    private func applyProtectedFlags(_ items: [PhotoItem]) -> [PhotoItem] {
        guard !protectedAssetIDs.isEmpty else { return items }
        return items.map { item in
            if !item.isProtected, protectedAssetIDs.contains(item.id) {
                return item.markedProtected()
            }
            return item
        }
    }

    // MARK: - Audit logging

    private func logDeletions(_ items: [PhotoItem], in group: PhotoGroup) {
        // Record the on-device close-call explanation (if any) as the reason the
        // keeper was chosen.
        let reason: String? = group.localExplanation
        let entries = items.map { item in
            AuditEntry(
                id: UUID(),
                timestamp: Date(),
                photoID: item.id,
                filename: nil,
                estimatedBytes: item.estimatedByteSize,
                groupSize: group.items.count,
                reason: reason,
                restored: false
            )
        }
        AuditLogger.shared.batchRecord(entries)
    }

    // MARK: - Progress helper

    private func publishScanState(progress: Double, message: String, phase: ScanPhase) {
        let eta = computeETA(progress: progress)
        scanState = .scanning(progress: progress, message: message, phase: phase, etaSeconds: eta)
    }

    /// Advances the per-item scoring progress. Scoring spans the 0.65–0.97 band
    /// (safely after video matching's max of 0.62, and running right up to the
    /// 0.98 finalising step). Called once per scored photo from `evaluateGroup`'s
    /// progress callback, hopped onto the main actor. Guarded on `.scanning` so a
    /// late callback that lands after the `.reviewing` transition can't flip the
    /// UI back to the progress screen.
    private func bumpScoringProgress(total: Int) {
        guard case .scanning = scanState else { return }
        scoredItemCount += 1
        let fraction = total > 0 ? Double(scoredItemCount) / Double(total) : 1
        let p = 0.65 + min(1.0, fraction) * 0.32
        publishScanState(progress: p,
                         message: "Scoring quality (\(scoredItemCount)/\(total))…",
                         phase: .scoring)
    }

    private func computeETA(progress: Double) -> Double? {
        // Skip the fast early fetching/grouping phases — their speed is not
        // representative of the hashing/scoring work that follows.
        guard let start = scanStartTime, progress > 0.08 else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 2.0 else { return nil }

        // Record sample and cap the window at 10 entries.
        etaSamples.append((elapsed: elapsed, progress: progress))
        if etaSamples.count > 10 { etaSamples.removeFirst() }

        // Overall velocity: stable reference from scan start but biased by
        // early fast phases.
        let overallVelocity = progress / elapsed

        // Recent-window velocity: adapts to the current phase's throughput rate.
        // Requires ≥ 3 samples and a meaningful time/progress delta to be useful.
        let windowVelocity: Double?
        if etaSamples.count >= 3 {
            let first = etaSamples.first!
            let last  = etaSamples.last!
            let dt = last.elapsed - first.elapsed
            let dp = last.progress - first.progress
            windowVelocity = (dt >= 1.0 && dp > 0) ? dp / dt : nil
        } else {
            windowVelocity = nil
        }

        // Blend 60 % recent-window + 40 % overall: reacts to phase-speed
        // changes while damping spikes from large instantaneous progress jumps.
        let velocity = windowVelocity.map { 0.6 * $0 + 0.4 * overallVelocity } ?? overallVelocity
        guard velocity > 0 else { return nil }
        return max(0, (1.0 - progress) / velocity)
    }
}
