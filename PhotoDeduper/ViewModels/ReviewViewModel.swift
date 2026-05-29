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
    var claudeExplanation: String?
    /// On-device close-call resolution explanation (no Claude required).
    var localExplanation: String?
    var isCloseCall: Bool
    var keptIndices: Set<Int> = []
    var aiReviews: [String: AIReviewResult] = [:]    // keyed by AIProvider.rawValue
    var aiErrors: [String: String] = [:]             // keyed by AIProvider.rawValue
    var reviewingProviders: Set<String> = []

    /// Origin label so the sidebar can hint whether a group came from a burst,
    /// a time window, a cross-format duplicate, or a video match.
    var origin: GroupOrigin = .timeWindow

    var isAIReviewing: Bool { !reviewingProviders.isEmpty }

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
    case crossFormat
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
    case crossFormat    = "Cross-format pass"
    case videoMatching  = "Video matching"
    case scoring        = "Quality scoring"
    case aiReview       = "AI review"
    case finalising     = "Finalising"
}

// MARK: - ViewModel

@MainActor
final class ReviewViewModel: ObservableObject {
    @Published var groups: [PhotoGroup] = []
    @Published var selectedGroupID: UUID?
    @Published var scanState: ScanState = .idle
    @Published var showConfirmDelete = false
    @Published var showSettings = false
    @Published var faceToFaceGroupID: UUID?
    @Published var lastReceipt: DeletionReceipt?
    @Published var undoBannerExpiresAt: Date?

    /// The currently running scan task, if any. Held so the user can cancel mid-scan.
    private var currentScanTask: Task<Void, Never>?
    private var scanStartTime: Date? {
        didSet { etaSamples.removeAll() }
    }
    /// Circular buffer of (elapsed seconds, progress) samples used by `computeETA`.
    /// Cleared automatically whenever `scanStartTime` is reset (new scan start or cancel).
    private var etaSamples: [(elapsed: Double, progress: Double)] = []
    /// Task that clears the undo banner once its 30-second window elapses.
    /// SwiftUI doesn't re-evaluate `hasActiveUndo` on its own; a timer is
    /// required to nil out `undoBannerExpiresAt` and trigger a view update.
    private var undoExpiryTask: Task<Void, Never>?
    let sessionStart = Date()

    /// Asset IDs the user has marked as belonging to protected albums.
    /// Read from UserDefaults at scan time; favourited items are auto-protected.
    private var protectedAssetIDs: Set<String> = []

    /// Re-entry guard against double-delete. Set on entry to deleteGroup /
    /// confirmDelete and cleared on every exit path so a second rapid tap
    /// (e.g. double-tap on the delete button) can't kick off a concurrent
    /// deletion of the same items.
    private var isDeleting = false

    var totalToDelete: Int {
        groups.reduce(0) { $0 + $1.itemsToDelete.count }
    }

    var estimatedFreedBytes: Int64 {
        groups.flatMap(\.itemsToDelete).reduce(Int64(0)) { total, item in
            if let bytes = item.fileByteSize {
                return total + bytes
            }
            return total + Int64(item.pixelWidth * item.pixelHeight * 3) / 20
        }
    }

    var hasActiveUndo: Bool {
        guard let expiry = undoBannerExpiresAt else { return false }
        return expiry > Date()
    }

    // MARK: - Entry points

    func startScan() {
        cancelScan()
        currentScanTask = Task { [weak self] in
            guard let self else { return }
            self.scanStartTime = Date()
            let lib = PhotoLibraryManager()
            guard await lib.requestAuthorization() else {
                if Task.isCancelled { return }
#if os(macOS)
                self.scanState = .error("Photo library access is required. Grant access in System Settings → Privacy & Security → Photos.")
#else
                self.scanState = .error("Photo library access is required. Open Settings → Privacy → Photos and grant access.")
#endif
                return
            }
            if Task.isCancelled { return }
            await self.refreshProtectedAssetIDs(library: lib)
            self.publishScanState(progress: 0.05, message: "Fetching photos…", phase: .fetching)

            let filter: PhotoLibraryManager.MediaFilter = UserDefaults.standard.bool(forKey: "scanVideosToo") ? .stillsAndVideos : .stillsOnly
            let items = await lib.fetchAllPhotos(filter: filter)
            if Task.isCancelled { return }
            await self.runPipeline(items)
        }
    }

    func startAlbumScan(album: PhotoAlbum) {
        cancelScan()
        currentScanTask = Task { [weak self] in
            guard let self else { return }
            self.scanStartTime = Date()
            let lib = PhotoLibraryManager()
            guard await lib.requestAuthorization() else {
                if Task.isCancelled { return }
#if os(macOS)
                self.scanState = .error("Photo library access is required. Grant access in System Settings → Privacy & Security → Photos.")
#else
                self.scanState = .error("Photo library access is required. Open Settings → Privacy → Photos and grant access.")
#endif
                return
            }
            if Task.isCancelled { return }
            await self.refreshProtectedAssetIDs(library: lib)
            self.publishScanState(progress: 0.05, message: "Loading \(album.title)…", phase: .fetching)

            let filter: PhotoLibraryManager.MediaFilter = UserDefaults.standard.bool(forKey: "scanVideosToo") ? .stillsAndVideos : .stillsOnly
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
                self.scanState = .error("DeDuper couldn't read the selected photos. They may belong to a Shared Library or a People album that isn't part of your personal library. Try \"Choose Album…\" instead.")
                return
            }

            await self.runPipeline(resolvedItems)
        }
    }

    func startFolderScan(url: URL) {
        cancelScan()
        currentScanTask = Task { [weak self] in
            guard let self else { return }
            self.scanStartTime = Date()
            self.publishScanState(progress: 0.02, message: "Reading folder…", phase: .fetching)
            let lib = PhotoLibraryManager()
            let filter: PhotoLibraryManager.MediaFilter = UserDefaults.standard.bool(forKey: "scanVideosToo") ? .stillsAndVideos : .stillsOnly
            let items = await lib.scanFolder(url, filter: filter)
            if Task.isCancelled { return }
            guard !items.isEmpty else {
                self.scanState = .error("No supported image files were found in the selected folder.")
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
        if case .scanning = scanState {
            scanState = .idle
        }
    }

    // MARK: - Shared pipeline

    private func runPipeline(_ items: [PhotoItem]) async {
        groups = []
        selectedGroupID = nil

        guard !items.isEmpty else {
            scanState = .reviewing
            return
        }

        let timeWindow       = UserDefaults.standard.object(forKey: "timeWindow")        as? Double ?? 30
        let hashThreshold    = UserDefaults.standard.object(forKey: "pHashThreshold")    as? Int    ?? 20
        let closeCallFraction = (UserDefaults.standard.object(forKey: "closeCallThreshold") as? Double ?? 15) / 100.0
        let crossFormatEnabled = UserDefaults.standard.bool(forKey: "crossFormatEnabled")

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

        // 3) Cross-format pass (HEIC ↔ JPG, scattered duplicates from sync issues).
        var crossFormatGroups: [[PhotoItem]] = []
        if crossFormatEnabled {
            publishScanState(progress: 0.42, message: "Looking for cross-format duplicates…", phase: .crossFormat)
            let alreadyGrouped = Set((verifiedBurst + verifiedTime).flatMap { $0 }.map(\.id))
            crossFormatGroups = await grouper.findCrossFormatDuplicates(
                among: stills,
                excluding: alreadyGrouped,
                threshold: max(5, hashThreshold - 3)
            ) { [weak self] p in
                Task { @MainActor [weak self] in
                    self?.publishScanState(progress: 0.42 + p * 0.08, message: "Looking for cross-format duplicates…", phase: .crossFormat)
                }
            }
        }

        // 4) Video duplicate detection.
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
            + crossFormatGroups.map { ($0, GroupOrigin.crossFormat) }
            + videoGroups.map { ($0, GroupOrigin.video) }
        guard !allGroups.isEmpty else { scanState = .reviewing; return }

        // 5) Scoring. Stream results into `groups` as each cluster is scored so
        // the user sees groups appear progressively (the chunked-scan UX).
        let scorer = PhotoScorer()
        groups = []
        for (i, (group, origin)) in allGroups.enumerated() {
            if Task.isCancelled { return }
            let qualities = await scorer.evaluateGroup(group)
            let scores = qualities.map(\.total)
            if Task.isCancelled { return }
            let sorted = scores.indices.sorted { scores[$0] > scores[$1] }
            var best = sorted.first ?? 0

            // Promote any protected item to proposed keeper. Track whether a
            // promotion occurred — if it did, skip local close-call resolution
            // so a heuristic winner can't override the user's explicit signal.
            let protectedIdx = group.firstIndex(where: { $0.isProtected })
            if let idx = protectedIdx { best = idx }

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
            for (idx, item) in group.enumerated() where item.isProtected { kept.insert(idx) }

            // On-device close-call resolution — skipped when a protected item was
            // explicitly promoted, so its proposedKeeperIndex stays correct.
            var localExplanation: String?
            if isCloseCall && protectedIdx == nil {
                if let (winnerIdx, reason) = resolveCloseCallLocally(qualities: qualities, ranked: sorted) {
                    best = winnerIdx
                    kept = [best]
                    for (idx, item) in group.enumerated() where item.isProtected { kept.insert(idx) }
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

            // Scoring spans 0.65–0.87, safely after video matching's max of 0.62.
            // (The old 0.60 start overlapped with video's [0.52, 0.62] range,
            // causing momentary backwards progress that corrupted ETA velocity.)
            let p = 0.65 + Double(i + 1) / Double(allGroups.count) * 0.22
            publishScanState(progress: p, message: "Scoring quality (\(i + 1)/\(allGroups.count))…", phase: .scoring)
        }

        if Task.isCancelled { return }

        // 6) AI close-call review via bundled proxy (GPT-4.1 mini).
        // Runs automatically when the user has premium and auto-review is enabled,
        // and the on-device resolver couldn't settle the call.
        // On HTTP 429 the group silently keeps its on-device result.
        let autoReviewEnabled = UserDefaults.standard.bool(forKey: "autoReviewEnabled")
        let hasPremium = EntitlementStore.shared.hasPremium
        let closeCallIndices = groups.indices.filter { groups[$0].isCloseCall && groups[$0].localExplanation == nil }
        if !closeCallIndices.isEmpty && autoReviewEnabled && hasPremium {
            let cap = 50
            let capped = Array(closeCallIndices.prefix(cap))
            let msg = capped.count < closeCallIndices.count
                ? "Asking AI about \(capped.count) of \(closeCallIndices.count) close calls (capped at \(cap))…"
                : "Asking AI about \(capped.count) close call(s)…"
            publishScanState(progress: 0.88, message: msg, phase: .aiReview)
            let reviewer = ProxyReviewer()
            await withTaskGroup(of: (Int, AIReviewResult?).self) { taskGroup in
                for idx in capped {
                    let items  = groups[idx].items
                    let scores = groups[idx].scores
                    taskGroup.addTask {
                        let result = try? await reviewer.review(items: items, scores: scores)
                        return (idx, result)
                    }
                }
                for await (idx, result) in taskGroup {
                    if Task.isCancelled { break }
                    guard let result, idx < groups.count else { continue }
                    // Surface the AI result as a suggestion the same way the
                    // on-demand requestAIReview path does — record it into
                    // aiReviews (keyed by provider) and clear any stale error /
                    // in-flight marker. The user accepts it via the existing
                    // Accept-AI-suggestion UI; we do NOT auto-apply the keeper.
                    groups[idx].aiReviews[result.provider.rawValue] = result
                    groups[idx].aiErrors.removeValue(forKey: result.provider.rawValue)
                    groups[idx].reviewingProviders.remove(result.provider.rawValue)
                }
            }
        }

        if Task.isCancelled { return }
        publishScanState(progress: 0.98, message: "Finishing up…", phase: .finalising)
        scanState = .reviewing
        ThumbnailCache.shared.warmup(for: groups)
        currentScanTask = nil
    }

    // MARK: - User actions

    func toggleKeep(groupID: UUID, itemIndex: Int) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        // Protected items cannot be marked for deletion via this toggle.
        if itemIndex < groups[i].items.count, groups[i].items[itemIndex].isProtected {
            return
        }
        if groups[i].keptIndices.contains(itemIndex) {
            groups[i].keptIndices.remove(itemIndex)
        } else {
            groups[i].keptIndices.insert(itemIndex)
        }
    }

    func requestAIReview(groupID: UUID, provider: AIProvider) async {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[idx].reviewingProviders.insert(provider.rawValue)

        let items  = groups[idx].items
        let scores = groups[idx].scores

        do {
            let result: AIReviewResult
            switch provider {
            case .claude:  result = try await ClaudeReviewer().review(items: items, scores: scores)
            case .openai:  result = try await OpenAIReviewer().review(items: items, scores: scores)
            case .groq:    result = try await GroqReviewer().review(items: items, scores: scores)
            case .proxy:   result = try await ProxyReviewer().review(items: items, scores: scores)
            }
            guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
            groups[i].aiReviews[provider.rawValue] = result
            groups[i].aiErrors.removeValue(forKey: provider.rawValue)
            groups[i].reviewingProviders.remove(provider.rawValue)
        } catch {
            guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
            // URLError's localizedDescription ("Could not connect to the server.") is too
            // generic. Map the most common codes to actionable messages; fall through to
            // localizedDescription for ReviewerError and any other typed errors.
            let message: String
            if let urlErr = error as? URLError {
                switch urlErr.code {
                case .notConnectedToInternet, .networkConnectionLost:
                    message = "No internet connection. Check your network and try again."
                case .timedOut:
                    message = "Request timed out — the server took too long to respond."
                case .cannotConnectToHost, .cannotFindHost:
                    message = "Could not reach the review server. Try again later."
                default:
                    message = "Network error: \(urlErr.localizedDescription)"
                }
            } else {
                message = error.localizedDescription
            }
            groups[i].aiErrors[provider.rawValue] = message
            groups[i].reviewingProviders.remove(provider.rawValue)
        }
    }

    func requestAIReviewForAllGroups(provider: AIProvider) async {
        let groupIDs = groups.map(\.id)
        guard !groupIDs.isEmpty else { return }
        let maxConcurrent = 4

        await withTaskGroup(of: Void.self) { taskGroup in
            var idx = 0
            for _ in 0..<min(maxConcurrent, groupIDs.count) {
                let id = groupIDs[idx]; idx += 1
                taskGroup.addTask { [weak self] in
                    await self?.requestAIReview(groupID: id, provider: provider)
                }
            }
            while await taskGroup.next() != nil {
                guard idx < groupIDs.count else { continue }
                let id = groupIDs[idx]; idx += 1
                taskGroup.addTask { [weak self] in
                    await self?.requestAIReview(groupID: id, provider: provider)
                }
            }
        }
    }

    func acceptAISuggestion(groupID: UUID, provider: AIProvider) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }),
              let result = groups[i].aiReviews[provider.rawValue] else { return }
        var kept: Set<Int> = [result.winnerIndex]
        for (idx, item) in groups[i].items.enumerated() where item.isProtected { kept.insert(idx) }
        groups[i].keptIndices = kept
    }

    func selectKeeper(groupID: UUID, itemIndex: Int) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        var kept: Set<Int> = [itemIndex]
        for (idx, item) in groups[i].items.enumerated() where item.isProtected { kept.insert(idx) }
        groups[i].keptIndices = kept
    }

    func selectNextGroup() {
        guard let id = selectedGroupID,
              let idx = groups.firstIndex(where: { $0.id == id }),
              idx + 1 < groups.count else { return }
        selectedGroupID = groups[idx + 1].id
    }

    func selectPreviousGroup() {
        guard let id = selectedGroupID,
              let idx = groups.firstIndex(where: { $0.id == id }),
              idx > 0 else { return }
        selectedGroupID = groups[idx - 1].id
    }

    func deleteGroup(groupID: UUID) async {
        guard !isDeleting else { return }
        isDeleting = true
        // NOTE: no function-scope defer here — this function returns before the
        // DispatchQueue.main.async block below runs its @Published mutations, so
        // the flag must survive past the return. Every synchronous early-return
        // path clears it explicitly; the deferred block clears it via its own
        // defer (covering both its internal guard-fail and normal completion).
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { isDeleting = false; return }
        let toDelete = groups[idx].itemsToDelete
        let groupSnapshot = groups[idx]  // capture before await; groups may mutate during suspension
        let mode: DeletionMode = UserDefaults.standard.bool(forKey: "holdForReview") ? .holdForReview : .directDelete

        let receipt: DeletionReceipt?
        do {
            if !toDelete.isEmpty {
                receipt = try await BatchDeleteManager.deleteItems(toDelete, mode: mode)
            } else {
                receipt = nil
            }
        } catch {
            isDeleting = false
            DispatchQueue.main.async { [weak self] in
                self?.scanState = .error(error.localizedDescription)
            }
            return
        }

        // Defer every @Published write to a fresh runloop tick. Resuming from
        // the `await` above can land while SwiftUI is mid-update (the
        // confirmation dialog is still dismissing, or a prior write here
        // would kick off `.animation(value: hasActiveUndo)` on ReviewView
        // and immediately re-enter view evaluation). Mutating @Published
        // properties in that window trips "Publishing changes from within
        // view updates". Reassign selection BEFORE removing the group so the
        // sidebar List's two-way binding never observes a missing selected ID.
        if let receipt {
            logDeletions(toDelete, in: groupSnapshot, receipt: receipt)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Clear the re-entry guard here, at the end of the deferred work —
            // not at function scope, which would fire before this block runs.
            // A defer covers both the internal `guard let currentIdx` early
            // return and the normal completion path exactly once. (If self is
            // nil the object is deallocating, so the flag is moot.)
            defer { self.isDeleting = false }
            if let receipt, !receipt.trashedAssetIDs.isEmpty {
                self.lastReceipt = receipt
                self.scheduleUndoExpiry(seconds: 30)
            }
            guard let currentIdx = self.groups.firstIndex(where: { $0.id == groupID }) else { return }
            if self.groups[currentIdx].id == self.selectedGroupID {
                if currentIdx + 1 < self.groups.count {
                    self.selectedGroupID = self.groups[currentIdx + 1].id
                } else if currentIdx > 0 {
                    self.selectedGroupID = self.groups[currentIdx - 1].id
                } else {
                    self.selectedGroupID = nil
                }
            }
            self.groups.remove(at: currentIdx)
        }
    }

    func confirmDelete() async {
        guard !isDeleting else { return }
        isDeleting = true
        // confirmDelete is fully awaited inline, so a function-scope defer is
        // safe here — it fires on every exit (success or catch). Placed after
        // the guard so a blocked re-entry can't clear the in-flight call's flag.
        defer { isDeleting = false }
        let toDeleteByGroup = groups.map { ($0, $0.itemsToDelete) }
        let toDelete = toDeleteByGroup.flatMap(\.1)
        let deletedCount = toDelete.count
        let freed = estimatedFreedBytes
        let keptCount = groups.reduce(0) { $0 + $1.keptIndices.count }
        let mode: DeletionMode = UserDefaults.standard.bool(forKey: "holdForReview") ? .holdForReview : .directDelete

        do {
            let receipt = try await BatchDeleteManager.deleteItems(toDelete, mode: mode)
            // Only show the undo banner when assets were actually trashed.
            // In holdForReview mode trashedAssetIDs is empty — the banner would
            // be misleading (nothing is in Recently Deleted to recover).
            if !receipt.trashedAssetIDs.isEmpty {
                self.lastReceipt = receipt
                self.scheduleUndoExpiry(seconds: 30)
            }
            for (group, items) in toDeleteByGroup where !items.isEmpty {
                logDeletions(items, in: group, receipt: receipt)
            }
            scanState = .done(keptCount: keptCount, deletedCount: deletedCount, freedBytes: freed)
        } catch {
            scanState = .error(error.localizedDescription)
        }
    }

    /// Opens Photos to Recently Deleted so the user can recover. Apple does
    /// not expose a programmatic restore API for already-deleted assets, so
    /// this is a navigation shortcut, not a true rollback.
    func attemptUndo() async {
        guard let receipt = lastReceipt else { return }
        _ = await BatchDeleteManager.restoreFromRecentlyDeleted(assetIDs: receipt.trashedAssetIDs)
        var ids: Set<UUID> = []
        for entry in AuditLogger.shared.sessionEntries(since: sessionStart) {
            if receipt.trashedAssetIDs.contains(entry.photoID) { ids.insert(entry.id) }
        }
        if !ids.isEmpty { AuditLogger.shared.markRestored(ids: ids) }
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

    func reset() {
        groups          = []
        selectedGroupID = nil
        scanState       = .idle
        lastReceipt     = nil
        undoBannerExpiresAt = nil
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
        let albumIDs = UserDefaults.standard.array(forKey: "protectedAlbumIDs") as? [String] ?? []
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
                return PhotoItem(
                    id: item.id,
                    source: item.source,
                    creationDate: item.creationDate,
                    pixelWidth: item.pixelWidth,
                    pixelHeight: item.pixelHeight,
                    mediaKind: item.mediaKind,
                    isFavorite: true,           // force-protected
                    burstIdentifier: item.burstIdentifier,
                    duration: item.duration,
                    fileByteSize: item.fileByteSize
                )
            }
            return item
        }
    }

    // MARK: - Audit logging

    private func logDeletions(_ items: [PhotoItem], in group: PhotoGroup, receipt: DeletionReceipt) {
        let aiProvider = group.aiReviews.keys.sorted().first
        let aiReason: String? = aiProvider
            .flatMap { group.aiReviews[$0] }
            .map(\.reason)
            ?? group.claudeExplanation
            ?? group.localExplanation
        let entries = items.map { item in
            AuditEntry(
                id: UUID(),
                timestamp: Date(),
                photoID: item.id,
                filename: nil,
                estimatedBytes: item.fileByteSize ?? Int64(item.pixelWidth * item.pixelHeight * 3) / 20,
                groupSize: group.items.count,
                aiProvider: aiProvider,
                aiReason: aiReason,
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
