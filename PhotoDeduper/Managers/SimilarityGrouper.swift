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
        progress: @escaping (Double) -> Void
    ) async -> [[PhotoItem]] {
        var result: [[PhotoItem]] = []
        let total = Double(max(groups.count, 1))

        for (i, group) in groups.enumerated() {
            if Task.isCancelled { return result }
            progress(Double(i) / total)

            // Compute hashes; nil means the thumbnail failed to load — excluded from all comparisons.
            var hashes: [UInt64?] = []
            for item in group {
                if Task.isCancelled { return result }
                hashes.append(await computeHash(for: item))
            }

            let n = group.count

            // Build pairwise adjacency — compare every pair, not just against the first photo.
            // Comparing only against hashes.first caused false negatives when the first photo
            // was an outlier, and false positives from coincidental hash closeness.
            var adjacent = Array(repeating: Array(repeating: false, count: n), count: n)
            for a in 0..<n {
                for b in (a + 1)..<n {
                    guard let ha = hashes[a], let hb = hashes[b] else { continue }
                    let similar = hammingDistance(ha, hb) < threshold
                    adjacent[a][b] = similar
                    adjacent[b][a] = similar
                }
            }

            // BFS connected components — photos similar to each other (even indirectly) cluster together.
            var visited = Array(repeating: false, count: n)
            var components: [[Int]] = []
            for start in 0..<n {
                guard !visited[start], hashes[start] != nil else { continue }
                var component = [Int]()
                var queue = [start]
                visited[start] = true
                while !queue.isEmpty {
                    let current = queue.removeFirst()
                    component.append(current)
                    for neighbor in 0..<n where !visited[neighbor] && adjacent[current][neighbor] {
                        visited[neighbor] = true
                        queue.append(neighbor)
                    }
                }
                if component.count >= 2 { components.append(component) }
            }

            // Emit every connected component as its own verified group. A single
            // input group can split into multiple distinct clusters (e.g. two
            // unrelated duplicate pairs that happened to share a time window or
            // burst), and dropping all but the largest would silently discard
            // real duplicates. Components are already filtered to size >= 2 above,
            // so isolated outliers (size 1) remain excluded.
            for component in components {
                let keepSet = Set(component)
                let verified = group.enumerated().compactMap { idx, item in keepSet.contains(idx) ? item : nil }
                if verified.count >= 2 { result.append(verified) }
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
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let ctx = CGContext(
                data: nil, width: 9, height: 8,
                bitsPerComponent: 8, bytesPerRow: 9,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
        guard let data = ctx.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: 72)

        var hash: UInt64 = 0
        for row in 0..<8 {
            for col in 0..<8 {
                if pixels[row * 9 + col] > pixels[row * 9 + col + 1] {
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
