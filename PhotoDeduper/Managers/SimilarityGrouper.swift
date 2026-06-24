import Foundation
import CoreGraphics

class SimilarityGrouper {

    // MARK: - Time + burst grouping

    /// Groups photos by `PHAsset.burstIdentifier` first (a single iOS burst
    /// belongs together regardless of time), then by time window for everything
    /// else.
    ///
    /// Returns a named tuple so callers can tag burst groups as `.burst` and
    /// time-window groups as `.timeWindow` without guessing after the fact.
    /// Single-item "bursts" (only one copy in the library) fall through to the
    /// time-window pass rather than being silently dropped.
    func groupByTime(_ items: [PhotoItem], windowSeconds: Double = 30)
        -> (burst: [[PhotoItem]], time: [[PhotoItem]])
    {
        // 1) Burst-identifier groups — iOS bursts always cluster together.
        var burstGroups: [String: [PhotoItem]] = [:]
        var nonBurstItems: [PhotoItem] = []
        for item in items {
            if let burst = item.burstIdentifier, !burst.isEmpty {
                burstGroups[burst, default: []].append(item)
            } else {
                nonBurstItems.append(item)
            }
        }

        var burstResult: [[PhotoItem]] = []
        for (_, burst) in burstGroups {
            if burst.count >= 2 {
                // Sort by creation date so burst-quality logic sees a consistent order.
                burstResult.append(burst.sorted {
                    ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
                })
            } else {
                // Single-item burst: fall through to the time-window pass so the
                // photo isn't silently dropped from deduplication entirely.
                nonBurstItems.append(contentsOf: burst)
            }
        }
        // Re-sort after appending single-burst items so the time-window algorithm
        // sees a monotonically-ordered sequence.
        nonBurstItems.sort { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }

        // 2) Time-window grouping on remaining items.
        var timeResult: [[PhotoItem]] = []
        var current: [PhotoItem] = []
        for item in nonBurstItems {
            guard let date = item.creationDate else { continue }
            if let lastDate = current.last?.creationDate,
               date.timeIntervalSince(lastDate) > windowSeconds {
                if current.count >= 2 { timeResult.append(current) }
                current = [item]
            } else {
                current.append(item)
            }
        }
        if current.count >= 2 { timeResult.append(current) }
        return (burst: burstResult, time: timeResult)
    }

    // MARK: - Visual similarity verification via difference hash

    func verifyVisualSimilarity(
        _ groups: [[PhotoItem]],
        threshold: Int = 15,
        maxConcurrent: Int = 8,
        progress: @escaping (Double) -> Void
    ) async -> [[PhotoItem]] {
        var result: [[PhotoItem]] = []
        // Progress is driven by items HASHED, not groups completed. A folder scan
        // is now a single big candidate group (see ReviewViewModel.runPipeline),
        // so per-group progress would sit at 0 until the very end and look frozen;
        // per-item keeps the bar moving through a large folder.
        let totalItems = Double(max(groups.reduce(0) { $0 + $1.count }, 1))
        var hashedItems = 0

        for group in groups {
            if Task.isCancelled { return result }
            let n = group.count

            // Compute hashes with bounded concurrency (mirrors
            // PhotoScorer.evaluateGroup). nil means the thumbnail failed to load —
            // that item is excluded from all comparisons. Sequential hashing was
            // fine for small time-window groups but would crawl through one large
            // folder group; fanning out keeps a big scan responsive.
            var hashes = [UInt64?](repeating: nil, count: n)
            await withTaskGroup(of: (Int, UInt64?).self) { tg in
                // min (not max(1, …)): an empty group yields limit 0 so the seed
                // loop is skipped — guards against indexing group[0] when n == 0.
                let limit = min(maxConcurrent, n)
                var next = 0
                while next < limit {
                    let index = next
                    let item = group[index]
                    tg.addTask { (index, await self.computeHash(for: item)) }
                    next += 1
                }
                for await (index, hash) in tg {
                    hashes[index] = hash
                    hashedItems += 1
                    progress(Double(hashedItems) / totalItems)
                    if next < n {
                        let i = next
                        let item = group[i]
                        tg.addTask { (i, await self.computeHash(for: item)) }
                        next += 1
                    }
                }
            }
            if Task.isCancelled { return result }

            // Build pairwise adjacency as LISTS rather than an n×n Bool matrix:
            // one large folder group would otherwise allocate n² Bools (e.g.
            // 5 000 files → 25 MB). The pairwise loop is still O(n²) in time, but
            // each comparison is a cheap XOR + popcount and memory stays O(edges).
            // We compare every pair (not just against the first photo): comparing
            // only against hashes.first caused false negatives when the first
            // photo was an outlier.
            var neighbors = Array(repeating: [Int](), count: n)
            for a in 0..<n {
                guard let ha = hashes[a] else { continue }
                for b in (a + 1)..<n {
                    guard let hb = hashes[b] else { continue }
                    if hammingDistance(ha, hb) < threshold {
                        neighbors[a].append(b)
                        neighbors[b].append(a)
                    }
                }
            }

            // BFS connected components — photos similar to each other (even
            // indirectly) cluster together. Emit every component of size >= 2 as
            // its own verified group: a single input group can split into multiple
            // distinct clusters (e.g. two unrelated duplicate pairs), and dropping
            // all but the largest would silently discard real duplicates. Isolated
            // outliers (size 1) remain excluded.
            var visited = Array(repeating: false, count: n)
            for start in 0..<n {
                guard !visited[start], hashes[start] != nil else { continue }
                var component = [Int]()
                var queue = [start]
                visited[start] = true
                while !queue.isEmpty {
                    let current = queue.removeFirst()
                    component.append(current)
                    for neighbor in neighbors[current] where !visited[neighbor] {
                        visited[neighbor] = true
                        queue.append(neighbor)
                    }
                }
                if component.count >= 2 {
                    let keepSet = Set(component)
                    let verified = group.enumerated().compactMap { idx, item in keepSet.contains(idx) ? item : nil }
                    if verified.count >= 2 { result.append(verified) }
                }
            }
        }

        return result
    }

    // MARK: - Hashing primitives

    /// Computes a 64-bit difference hash for the given item via its thumbnail.
    /// Returned hashes can be compared across formats: the resampling step
    /// neutralises HEIC vs JPG vs PNG encoding differences.
    func computeHash(for item: PhotoItem) async -> UInt64? {
        guard let thumb = await PhotoLibraryManager.loadThumbnail(
            for: item, size: CGSize(width: 9, height: 8)
        ) else { return nil }
        return differenceHash(thumb)
    }

    func differenceHash(_ image: CGImage) -> UInt64? {
        // Pass bytesPerRow: 0 so CoreGraphics picks an optimal (possibly padded)
        // row stride; we then read the actual stride from the context rather than
        // assuming a tight 9-byte rows. A hardcoded stride would read the wrong
        // bytes if CG padded the rows, silently producing garbage hashes.
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let ctx = CGContext(
                data: nil, width: 9, height: 8,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
        guard let data = ctx.data else { return nil }
        let stride = ctx.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: stride * 8)

        var hash: UInt64 = 0
        for row in 0..<8 {
            for col in 0..<8 {
                if pixels[row * stride + col] > pixels[row * stride + col + 1] {
                    hash |= (1 << (row * 8 + col))
                }
            }
        }
        return hash
    }

    func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}
