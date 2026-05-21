import Foundation
import CoreGraphics

class SimilarityGrouper {

    // MARK: - Time-based grouping

    func groupByTime(_ items: [PhotoItem], windowSeconds: Double = 30) -> [[PhotoItem]] {
        var groups: [[PhotoItem]] = []
        var current: [PhotoItem] = []

        for item in items {
            guard let date = item.creationDate else { continue }
            if let lastDate = current.last?.creationDate,
               date.timeIntervalSince(lastDate) > windowSeconds {
                if current.count >= 2 { groups.append(current) }
                current = [item]
            } else {
                current.append(item)
            }
        }
        if current.count >= 2 { groups.append(current) }
        return groups
    }

    // MARK: - Visual similarity verification via difference hash

    func verifyVisualSimilarity(
        _ groups: [[PhotoItem]],
        threshold: Int = 15,
        progress: @escaping (Double) -> Void
    ) async -> [[PhotoItem]] {
        var result: [[PhotoItem]] = []
        let total = Double(groups.count)

        for (i, group) in groups.enumerated() {
            if Task.isCancelled { return result }
            progress(Double(i) / total)

            // Compute hashes; nil means the thumbnail failed to load — excluded from all comparisons.
            var hashes: [UInt64?] = []
            for item in group {
                if Task.isCancelled { return result }
                if let thumb = await PhotoLibraryManager.loadThumbnail(
                    for: item, size: CGSize(width: 9, height: 8)
                ), let hash = differenceHash(thumb) {
                    hashes.append(hash)
                } else {
                    hashes.append(nil)
                }
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

            // Keep the largest component (the main burst cluster); isolated outliers are excluded.
            guard let largest = components.max(by: { $0.count < $1.count }) else { continue }
            let keepSet = Set(largest)
            let verified = group.enumerated().compactMap { idx, item in keepSet.contains(idx) ? item : nil }
            if verified.count >= 2 { result.append(verified) }
        }

        return result
    }

    // MARK: - Difference hash (dHash)

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
