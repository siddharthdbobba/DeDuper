import Foundation
import CoreImage
import Vision

/// Quality score per photo. Now a richer struct than a bare Double so the UI
/// can show *why* a photo won — sharpness vs eye-state vs exposure.
struct PhotoQuality {
    let total: Double          // [0, 1]
    let sharpness: Double      // [0, 1]
    let exposure: Double       // [0, 1]
    let faceScore: Double?     // nil if no faces detected (or video)
    let faceCount: Int
    let eyesOpen: Double       // [0, 1] when faceCount > 0; 0 otherwise
    let aesthetics: Double?    // [0, 1] whole-image aesthetic score (Vision, macOS 15+/iOS 18+); nil when unavailable
    var isUndecodable: Bool = false  // true when the item's pixels couldn't be loaded/decoded; such items are never auto-deleted

    /// A zeroed score — used for cancelled evaluations.
    static let zero = PhotoQuality(total: 0, sharpness: 0, exposure: 0, faceScore: nil, faceCount: 0, eyesOpen: 0, aesthetics: nil)
    /// A zeroed score flagged undecodable so `runPipeline` never auto-deletes the item.
    static let undecodable = PhotoQuality(total: 0, sharpness: 0, exposure: 0, faceScore: nil, faceCount: 0, eyesOpen: 0, aesthetics: nil, isUndecodable: true)
}

class PhotoScorer {

    /// Shared `CIContext` reused across every `evaluate` call. A `CIContext` is
    /// expensive to construct (it allocates GPU/Metal state) and is thread-safe,
    /// so we build it once instead of per-photo.
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Returns one `PhotoQuality` per item, in the same order.
    ///
    /// Concurrency is bounded to `maxConcurrent` evaluations in flight. Each
    /// evaluation decodes a thumbnail and runs Core Image + two Vision passes, so
    /// an unbounded fan-out on a large group (e.g. a big near-duplicate cluster)
    /// spawned hundreds of these at once — thrashing memory and oversubscribing
    /// the GPU/Vision queues until throughput collapsed. `onItemScored` fires once
    /// per completed item so callers can report item-level progress.
    func evaluateGroup(
        _ items: [PhotoItem],
        maxConcurrent: Int = 4,
        onItemScored: (@Sendable () -> Void)? = nil
    ) async -> [PhotoQuality] {
        await withTaskGroup(of: (Int, PhotoQuality).self) { group in
            // min (not max(1, …)): an empty group must yield limit 0 so the seed
            // loop is skipped and we return [] — max(1, …) would index items[0].
            let limit = min(maxConcurrent, items.count)
            var next = 0
            // Seed the group with up to `limit` concurrent evaluations.
            while next < limit {
                let index = next
                let item = items[index]
                group.addTask { (index, await self.evaluate(item)) }
                next += 1
            }
            var results = [(Int, PhotoQuality)]()
            results.reserveCapacity(items.count)
            // As each finishes, report progress and enqueue the next item so no
            // more than `limit` evaluations ever run at once.
            for await result in group {
                results.append(result)
                onItemScored?()
                if next < items.count {
                    let index = next
                    let item = items[index]
                    group.addTask { (index, await self.evaluate(item)) }
                    next += 1
                }
            }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    func evaluate(_ item: PhotoItem) async -> PhotoQuality {
        // Videos: skip Core Image scoring entirely. Use file size and resolution
        // (when known) as a crude quality proxy — bigger ≈ higher bitrate ≈ better.
        if item.isVideo {
            // Decodability gate: a corrupt/undecodable video must never out-score
            // a healthy duplicate on raw resolution/size alone. Reuse the existing
            // video keyframe loader (PHImageManager / AVAssetImageGenerator under
            // the hood). A nil keyframe means the file can't be read here (corrupt,
            // or an iCloud video not downloaded at scan time) — flag it undecodable
            // so runPipeline keeps it rather than queuing it for deletion.
            guard await PhotoLibraryManager.loadThumbnail(
                for: item, size: CGSize(width: 64, height: 64)
            ) != nil else {
                return .undecodable
            }

            let pixels = Double(max(1, item.pixelWidth * item.pixelHeight))
            let bytes  = Double(item.fileByteSize ?? 0)
            // Megapixels normalised against 4K (~8 MP). File size in MB normalised against 200 MB.
            let resScore  = min(1.0, pixels / 8_000_000.0)
            let sizeScore = min(1.0, bytes / 200_000_000.0)
            let combined = max(resScore, sizeScore)
            return PhotoQuality(
                total: combined,
                sharpness: resScore,
                exposure: 0.5,
                faceScore: nil,
                faceCount: 0,
                eyesOpen: 0,
                aesthetics: nil
            )
        }

        guard let cgImage = await PhotoLibraryManager.loadThumbnail(
            for: item, size: CGSize(width: 512, height: 512)
        ) else {
            // Couldn't load/decode (corrupt, or an iCloud asset not downloaded at
            // scan time) — flag undecodable so runPipeline never auto-deletes it.
            return .undecodable
        }

        let ci = CIImage(cgImage: cgImage)
        let sharpness = computeSharpness(ci, context: ciContext)
        let exposure  = computeExposure(ci, context: ciContext)

        // Face analysis and aesthetic scoring are two independent Vision passes,
        // so kick them off concurrently and await both rather than running them
        // back-to-back. Face analysis is cheap (~10-30 ms per photo at 800px);
        // aesthetics is the whole-image quality model (macOS 15+/iOS 18+), nil on
        // the iOS 17 build / macOS 14, where we fall back to the technical-only
        // weighting below.
        async let faceTask = FaceAnalyzer.analyze(cgImage)
        async let aestheticsTask = AestheticsScorer.score(ci)
        let face = await faceTask
        let aesthetics = await aestheticsTask

        // Weighting — goal is the best OVERALL photo, not the most-open eyes.
        //   - When the aesthetics model is available it leads the decision; eye
        //     openness is only a minor input folded into face.score (see FaceAnalyzer).
        //   - Without it, fall back to face/sharpness/exposure.
        let total: Double
        if face.faceCount > 0 {
            if let a = aesthetics {
                // Split into terms — a single 4-way literal sum makes Swift's
                // overload resolution pathologically slow ("unable to type-check
                // in reasonable time").
                let wAesthetic = 0.30 * a
                let wFace      = 0.30 * face.score
                let wSharp     = 0.25 * sharpness
                let wExposure  = 0.15 * exposure
                total = wAesthetic + wFace + wSharp + wExposure
            } else {
                total = 0.45 * face.score + 0.35 * sharpness + 0.20 * exposure
            }
        } else {
            if let a = aesthetics {
                total = 0.40 * a + 0.45 * sharpness + 0.15 * exposure
            } else {
                total = 0.65 * sharpness + 0.35 * exposure
            }
        }

        return PhotoQuality(
            total: total,
            sharpness: sharpness,
            exposure: exposure,
            faceScore: face.faceCount > 0 ? face.score : nil,
            faceCount: face.faceCount,
            eyesOpen: face.meanEyeOpenness,
            aesthetics: aesthetics
        )
    }

    // MARK: - Sharpness via edge mean, peak, and standard deviation

    private func computeSharpness(_ image: CIImage, context ctx: CIContext) -> Double {
        let edges = image
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
            .applyingFilter("CIEdges", parameters: ["inputIntensity": 1.0])
        let extent = CIVector(cgRect: edges.extent)

        // Mean edge intensity
        let avg = edges.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: extent])
        var avgPx = [Float](repeating: 0, count: 4)
        ctx.render(avg, toBitmap: &avgPx, rowBytes: 16,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBAf, colorSpace: CGColorSpaceCreateDeviceRGB())

        // Peak edge intensity
        let peak = edges.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: extent])
        var peakPx = [Float](repeating: 0, count: 4)
        ctx.render(peak, toBitmap: &peakPx, rowBytes: 16,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBAf, colorSpace: CGColorSpaceCreateDeviceRGB())

        // Standard deviation of edge intensity via E[X²] - E[X]².
        // A sharp image has a wide edge distribution (high stddev); a blurry one is uniformly low.
        let edgesSquared = edges.applyingFilter("CIMultiplyCompositing",
            parameters: [kCIInputImageKey: edges, kCIInputBackgroundImageKey: edges])
        var sqAvgPx = [Float](repeating: 0, count: 4)
        let sqExtent = CIVector(cgRect: edgesSquared.extent)
        let avgSq = edgesSquared.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: sqExtent])
        ctx.render(avgSq, toBitmap: &sqAvgPx, rowBytes: 16,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBAf, colorSpace: CGColorSpaceCreateDeviceRGB())

        let mean    = Double(avgPx[0])
        let maxEdge = Double(peakPx[0])
        let sqMean  = Double(sqAvgPx[0])
        let stddev  = sqrt(max(0, sqMean - mean * mean))

        // Sigmoid normalization avoids hard saturation at 1.0 so similar-quality photos
        // produce distinct scores rather than all clamping to the maximum.
        // f(x) = x / (x + 0.5) maps the unbounded raw value to (0, 1).
        let raw = mean * 3.0 + maxEdge * 1.5 + stddev * 5.0
        return raw / (raw + 0.5)
    }

    // MARK: - Exposure quality via histogram clipping

    private func computeExposure(_ image: CIImage, context ctx: CIContext) -> Double {
        let hist = image.applyingFilter("CIAreaHistogram", parameters: [
            kCIInputExtentKey: CIVector(cgRect: image.extent),
            "inputCount": 256,
            "inputScale": 1.0
        ])

        var histData = [Float](repeating: 0, count: 256 * 4)
        ctx.render(hist, toBitmap: &histData, rowBytes: 256 * 16,
                   bounds: CGRect(x: 0, y: 0, width: 256, height: 1),
                   format: .RGBAf, colorSpace: CGColorSpaceCreateDeviceRGB())

        let buckets = stride(from: 0, to: 256 * 4, by: 4).map { Double(histData[$0]) }
        let total = buckets.reduce(0, +)
        guard total > 0 else { return 0.5 }

        // Wider bins capture shoulder clipping before hard saturation.
        let underexposed = buckets[0..<26].reduce(0, +) / total   // bins 0–25
        let overexposed  = buckets[230..<256].reduce(0, +) / total // bins 230–255

        // Quadratic overexposure penalty: 10% blown → –0.40; 20% blown → score capped at 0.
        let overPenalty  = min(1.0, overexposed * overexposed * 20.0 + overexposed * 2.0)
        let underPenalty = min(1.0, underexposed * 1.5)
        return max(0, 1.0 - underPenalty - overPenalty)
    }
}

/// Whole-image aesthetic quality via Apple's Vision model.
///
/// Available on macOS 15 / iOS 18+. Returns a score normalised to `[0, 1]`
/// (Vision reports `[-1, 1]`), or `nil` when the API is unavailable — e.g. the
/// iOS 17 build or macOS 14 — so callers fall back to technical metrics. The
/// `#available` guard weak-links the symbol, so this compiles and runs at the
/// current deployment target regardless of whether it's bumped to 15.
enum AestheticsScorer {
    static func score(_ image: CIImage) async -> Double? {
        guard #available(macOS 15.0, iOS 18.0, *) else { return nil }
        let request = CalculateImageAestheticsScoresRequest()
        do {
            let observation = try await request.perform(on: image)
            return (Double(observation.overallScore) + 1.0) / 2.0
        } catch {
            return nil
        }
    }
}
