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

    /// Consecutive per-item watchdog timeouts, and the latch they trip.
    ///
    /// A working watchdog alone isn't enough when Vision itself is jammed
    /// system-wide (mediaanalysisd/ANE saturated — e.g. a bulk photo import
    /// running alongside the scan). Every item would then burn the full
    /// `perItemTimeout`, turning a few-minute scan into hours of timeouts.
    /// After `timeoutsBeforeGivingUpOnVision` consecutive timeouts we stop
    /// asking Vision anything for the rest of the scan and score on Core Image
    /// sharpness/exposure alone — the same fallback path already used on OS
    /// versions without the aesthetics model. Any success resets the counter.
    private let stateLock = NSLock()
    private var consecutiveTimeouts = 0
    private var visionDisabled = false

    static let timeoutsBeforeGivingUpOnVision = 3

    /// True once the Vision circuit breaker has tripped.
    private var isVisionDisabled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return visionDisabled
    }

    private func recordTimeout() {
        stateLock.lock(); defer { stateLock.unlock() }
        consecutiveTimeouts += 1
        if consecutiveTimeouts >= Self.timeoutsBeforeGivingUpOnVision { visionDisabled = true }
    }

    private func recordSuccess() {
        stateLock.lock(); defer { stateLock.unlock() }
        consecutiveTimeouts = 0
    }

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
                group.addTask { (index, await self.evaluate(item, timeoutSeconds: Self.perItemTimeout)) }
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
                    group.addTask { (index, await self.evaluate(item, timeoutSeconds: Self.perItemTimeout)) }
                    next += 1
                }
            }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    /// Hard per-item ceiling so a single pathological asset can never freeze the
    /// whole scan. `evaluate` awaits a thumbnail decode plus two Vision passes
    /// and, for videos, a synchronous `AVAssetImageGenerator` frame grab — none
    /// of which carry their own timeout. Because `evaluateGroup` (and the
    /// sequential group loop in `runPipeline`) block until every item finishes,
    /// one wedged item would otherwise pin the progress bar forever (the
    /// "stuck at N%" stall). This value is deliberately generous — far above any
    /// legitimate per-item scoring time — so it never trips on a merely slow but
    /// healthy asset (large RAW, high-res video keyframe).
    static let perItemTimeout: Double = 20

    /// `evaluate` wrapped in a watchdog. Whichever finishes first wins: a real
    /// evaluation yields the quality; the timer yields `.undecodable`, which
    /// `runPipeline` always keeps and never auto-deletes, so the scan proceeds
    /// instead of hanging.
    ///
    /// This deliberately races two *unstructured* tasks against a shared
    /// one-shot continuation rather than using `withTaskGroup`. A task group
    /// implicitly awaits its remaining children when the body returns, so the
    /// previous group-based version could not actually escape a wedged item: the
    /// timer won the race, and then `withTaskGroup` blocked on the very
    /// evaluation it was supposed to abandon. Unstructured tasks have no such
    /// join — the first `resume` returns to the caller and the loser finishes (or
    /// never finishes) in the background with its result discarded.
    private func evaluate(_ item: PhotoItem, timeoutSeconds: Double) async -> PhotoQuality {
        await withCheckedContinuation { (continuation: CheckedContinuation<PhotoQuality, Never>) in
            let once = ResumeOnce(continuation)
            let work = Task { await self.evaluate(item) }
            Task {
                let quality = await work.value
                self.recordSuccess()
                once.resume(with: quality)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                self.recordTimeout()
                once.resume(with: .undecodable)
                // Best-effort: Vision/AVFoundation may ignore cancellation, but
                // the caller is already free either way.
                work.cancel()
            }
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
        let face: FaceAnalyzer.Result
        let aesthetics: Double?
        if isVisionDisabled {
            // Circuit breaker tripped — Vision is not answering. Score on the
            // technical metrics only rather than waiting out another timeout.
            face = FaceAnalyzer.noFaces
            aesthetics = nil
        } else {
            async let faceTask = FaceAnalyzer.analyze(cgImage)
            async let aestheticsTask = AestheticsScorer.score(ci)
            face = await faceTask
            aesthetics = await aestheticsTask
        }

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
