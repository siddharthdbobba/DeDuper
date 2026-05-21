import Foundation
import Photos
import SwiftUI

// MARK: - Model

struct PhotoGroup: Identifiable {
    let id = UUID()
    var items: [PhotoItem]
    var proposedKeeperIndex: Int
    var scores: [Double]
    var claudeExplanation: String?
    var isCloseCall: Bool
    var keptIndices: Set<Int> = []
    var aiReviews: [String: AIReviewResult] = [:]    // keyed by AIProvider.rawValue
    var aiErrors: [String: String] = [:]             // keyed by AIProvider.rawValue
    var reviewingProviders: Set<String> = []

    var isAIReviewing: Bool { !reviewingProviders.isEmpty }

    /// The lowest kept index; used for the sidebar thumbnail and lightbox status label.
    var primaryKeeperIndex: Int { keptIndices.min() ?? proposedKeeperIndex }

    /// Raw quality scores for display; the scorer's sigmoid normalization already provides
    /// meaningful spread, so no artificial stretching is applied here.
    var displayScores: [Double] { scores }

    var itemsToDelete: [PhotoItem] {
        items.enumerated().compactMap { i, item in keptIndices.contains(i) ? nil : item }
    }

    var itemsToKeep: [PhotoItem] {
        items.enumerated().compactMap { i, item in keptIndices.contains(i) ? item : nil }
    }
}

enum ScanState {
    case idle
    case scanning(progress: Double, message: String)
    case reviewing
    case done(keptCount: Int, deletedCount: Int, freedBytes: Int64)
    case error(String)
}

// MARK: - ViewModel

@MainActor
final class ReviewViewModel: ObservableObject {
    @Published var groups: [PhotoGroup] = []
    @Published var selectedGroupID: UUID?
    @Published var scanState: ScanState = .idle
    @Published var showConfirmDelete = false
    @Published var showSettings = false

    /// The currently running scan task, if any. Held so the user can cancel mid-scan.
    private var currentScanTask: Task<Void, Never>?

    var totalToDelete: Int {
        groups.reduce(0) { $0 + $1.itemsToDelete.count }
    }

    var estimatedFreedBytes: Int64 {
        groups.flatMap(\.itemsToDelete).reduce(Int64(0)) { total, item in
            total + Int64(item.pixelWidth * item.pixelHeight * 3) / 20
        }
    }

    // MARK: - Entry points

    func startScan() {
        cancelScan()
        currentScanTask = Task { [weak self] in
            guard let self else { return }
            let lib = PhotoLibraryManager()
            guard await lib.requestAuthorization() else {
                if Task.isCancelled { return }
                self.scanState = .error("Photo library access is required. Grant access in System Settings → Privacy → Photos.")
                return
            }
            if Task.isCancelled { return }
            self.scanState = .scanning(progress: 0.05, message: "Fetching photos…")
            let items = await lib.fetchAllPhotos()
            if Task.isCancelled { return }
            await self.runPipeline(items)
        }
    }

    func startAlbumScan(album: PhotoAlbum) {
        cancelScan()
        currentScanTask = Task { [weak self] in
            guard let self else { return }
            let lib = PhotoLibraryManager()
            guard await lib.requestAuthorization() else {
                if Task.isCancelled { return }
                self.scanState = .error("Photo library access is required. Grant access in System Settings → Privacy → Photos.")
                return
            }
            if Task.isCancelled { return }
            self.scanState = .scanning(progress: 0.05, message: "Loading \(album.title)…")
            let items = await lib.fetchPhotos(from: album.collection)
            if Task.isCancelled { return }
            await self.runPipeline(items)
        }
    }

    func startFolderScan(url: URL) {
        cancelScan()
        currentScanTask = Task { [weak self] in
            guard let self else { return }
            self.scanState = .scanning(progress: 0.02, message: "Reading folder…")
            let lib = PhotoLibraryManager()
            let items = await lib.scanFolder(url)
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
        // Only revert UI state if we were actively scanning; preserve .reviewing/.done/.error.
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
        let hashThreshold    = UserDefaults.standard.object(forKey: "pHashThreshold")    as? Int    ?? 12
        let closeCallFraction = (UserDefaults.standard.object(forKey: "closeCallThreshold") as? Double ?? 15) / 100.0

        if Task.isCancelled { return }
        scanState = .scanning(progress: 0.10, message: "Finding time-adjacent groups…")
        let grouper   = SimilarityGrouper()
        let rawGroups = grouper.groupByTime(items, windowSeconds: timeWindow)

        if Task.isCancelled { return }
        guard !rawGroups.isEmpty else { scanState = .reviewing; return }

        let verifiedGroups = await grouper.verifyVisualSimilarity(rawGroups, threshold: hashThreshold) { [weak self] p in
            Task { @MainActor [weak self] in
                self?.scanState = .scanning(progress: 0.10 + p * 0.30, message: "Verifying visual similarity…")
            }
        }

        if Task.isCancelled { return }
        guard !verifiedGroups.isEmpty else { scanState = .reviewing; return }

        let scorer = PhotoScorer()
        var photoGroups: [PhotoGroup] = []
        photoGroups.reserveCapacity(verifiedGroups.count)

        for (i, group) in verifiedGroups.enumerated() {
            if Task.isCancelled { return }
            let scores = await scorer.scoreGroup(group)
            if Task.isCancelled { return }
            let sorted = scores.indices.sorted { scores[$0] > scores[$1] }
            let best   = sorted[0]

            var isCloseCall = false
            if sorted.count > 1 {
                let top = scores[best], second = scores[sorted[1]]
                isCloseCall = top > 0 && (top - second) / top < closeCallFraction
            }

            photoGroups.append(PhotoGroup(
                items: group, proposedKeeperIndex: best,
                scores: scores, isCloseCall: isCloseCall,
                keptIndices: [best]
            ))

            let p = 0.40 + Double(i + 1) / Double(verifiedGroups.count) * 0.30
            scanState = .scanning(progress: p, message: "Scoring quality (\(i + 1)/\(verifiedGroups.count))…")
        }

        if Task.isCancelled { return }

        let closeCallIndices = photoGroups.indices.filter { photoGroups[$0].isCloseCall }
        if !closeCallIndices.isEmpty && KeychainHelper.retrieve(key: "claude_api_key") != nil {
            scanState = .scanning(progress: 0.75, message: "Asking AI about \(closeCallIndices.count) close call(s)…")
            let reviewer = ClaudeReviewer()
            await withTaskGroup(of: (Int, AIReviewResult?).self) { taskGroup in
                for idx in closeCallIndices {
                    let items  = photoGroups[idx].items
                    let scores = photoGroups[idx].scores
                    taskGroup.addTask { (idx, try? await reviewer.review(items: items, scores: scores)) }
                }
                for await (idx, result) in taskGroup {
                    if Task.isCancelled { break }
                    guard let result else { continue }
                    // Only store the explanation — do not change keptIndices.
                    // The highest-scoring photo always remains the automatic selection;
                    // the user can accept the AI suggestion manually via "Ask AI" → Accept.
                    photoGroups[idx].claudeExplanation = result.reason
                }
            }
        }

        if Task.isCancelled { return }
        scanState = .scanning(progress: 0.98, message: "Finishing up…")
        groups         = photoGroups
        selectedGroupID = photoGroups.first?.id
        scanState      = .reviewing
        currentScanTask = nil
    }

    // MARK: - User actions

    func toggleKeep(groupID: UUID, itemIndex: Int) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        if groups[i].keptIndices.contains(itemIndex) {
            // Allow marking every photo in a group for removal — the user may
            // legitimately want to discard the whole burst.
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
            }
            guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
            groups[i].aiReviews[provider.rawValue] = result
            groups[i].aiErrors.removeValue(forKey: provider.rawValue)
            groups[i].reviewingProviders.remove(provider.rawValue)
        } catch {
            guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
            groups[i].aiErrors[provider.rawValue] = error.localizedDescription
            groups[i].reviewingProviders.remove(provider.rawValue)
        }
    }

    /// Runs the given provider against every group in the current scan, with
    /// bounded concurrency so we don't fan out into a rate-limit problem on
    /// larger albums. Snapshots the group IDs up front so deletions / mutations
    /// mid-pass don't fault the loop.
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
        groups[i].keptIndices = [result.winnerIndex]
    }

    func deleteGroup(groupID: UUID) async {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let toDelete = groups[idx].itemsToDelete
        do {
            if !toDelete.isEmpty { try await BatchDeleteManager.deleteItems(toDelete) }
            let wasSelected = groups[idx].id == selectedGroupID
            groups.remove(at: idx)
            if wasSelected {
                selectedGroupID = groups.isEmpty ? nil : groups[min(idx, groups.count - 1)].id
            }
        } catch {
            scanState = .error(error.localizedDescription)
        }
    }

    func confirmDelete() async {
        let toDelete     = groups.flatMap(\.itemsToDelete)
        let deletedCount = toDelete.count
        let freed        = estimatedFreedBytes
        let keptCount    = groups.reduce(0) { $0 + $1.keptIndices.count }

        do {
            try await BatchDeleteManager.deleteItems(toDelete)
            scanState = .done(keptCount: keptCount, deletedCount: deletedCount, freedBytes: freed)
        } catch {
            scanState = .error(error.localizedDescription)
        }
    }

    func reset() {
        groups          = []
        selectedGroupID = nil
        scanState       = .idle
    }
}
