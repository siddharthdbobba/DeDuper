import Foundation
import CoreImage

class PhotoScorer {

    func scoreGroup(_ items: [PhotoItem]) async -> [Double] {
        var scores = [Double](repeating: 0, count: items.count)
        for (i, item) in items.enumerated() {
            if Task.isCancelled { return scores }
            scores[i] = await scoreItem(item)
        }
        return scores
    }

    func scoreItem(_ item: PhotoItem) async -> Double {
        guard let cgImage = await PhotoLibraryManager.loadThumbnail(
            for: item, size: CGSize(width: 800, height: 800)
        ) else { return 0.0 }  // can't evaluate → never chosen as keeper

        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        let ci = CIImage(cgImage: cgImage)
        let sharpness = computeSharpness(ci, context: ctx)
        let exposure  = computeExposure(ci, context: ctx)
        return 0.65 * sharpness + 0.35 * exposure
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
