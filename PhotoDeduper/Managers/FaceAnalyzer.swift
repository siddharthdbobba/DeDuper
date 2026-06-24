import Foundation
import Vision
import CoreGraphics

/// On-device face / eye / smile analysis used as a third dimension in
/// `PhotoScorer` and as the automatic close-call resolver.
///
/// All work happens locally via Apple's Vision framework — no network, no
/// uploads, no API key required.
struct FaceAnalyzer {

    struct Result {
        /// Aggregate face-quality score in `[0, 1]`. Higher is better.
        let score: Double
        /// Number of detected faces. Zero is meaningful — it means face-based
        /// scoring should not be weighted in for this photo.
        let faceCount: Int
        /// Mean eye-open confidence in `[0, 1]` across all detected faces.
        let meanEyeOpenness: Double
    }

    /// Empty/safe result for photos that don't contain analyzable faces.
    static let noFaces = Result(score: 0, faceCount: 0, meanEyeOpenness: 0)

    /// Analyzes a single thumbnail. Returns `.noFaces` if no faces were detected
    /// or if Vision failed. Callers must inspect `faceCount` before mixing the
    /// score into a combined photo score — a photo with no faces shouldn't
    /// inherit a zero face-score against a photo with high face-score.
    static func analyze(_ image: CGImage) async -> Result {
        await withCheckedContinuation { continuation in
            // Detect face landmarks (eyes + mouth) plus per-attribute confidence.
            let landmarksRequest = VNDetectFaceLandmarksRequest()
            // Capture quality is independent of landmarks — sharpness, exposure,
            // and subject motion baked into a single score. Vision performs this
            // request locally on macOS 11+; we only consume it when present.
            let qualityRequest = VNDetectFaceCaptureQualityRequest()

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([landmarksRequest, qualityRequest])
            } catch {
                continuation.resume(returning: noFaces)
                return
            }

            guard let observations = landmarksRequest.results, !observations.isEmpty else {
                continuation.resume(returning: noFaces)
                return
            }

            let qualityObservations = qualityRequest.results ?? []

            // Eye openness — Vision exposes left/right eye landmarks. We use the
            // height-to-width aspect ratio of the eye polygon as a proxy: closed
            // eyes flatten the polygon and produce a low ratio.
            var eyeOpennessSum: Double = 0
            var eyeOpennessCount = 0
            var smileLikely = false

            for face in observations {
                if let left = face.landmarks?.leftEye {
                    let openness = eyeAspect(of: left.normalizedPoints)
                    eyeOpennessSum += openness
                    eyeOpennessCount += 1
                }
                if let right = face.landmarks?.rightEye {
                    let openness = eyeAspect(of: right.normalizedPoints)
                    eyeOpennessSum += openness
                    eyeOpennessCount += 1
                }
                if let outerLips = face.landmarks?.outerLips {
                    smileLikely = smileLikely || isLikelySmile(outerLips.normalizedPoints)
                }
            }

            let meanEye = eyeOpennessCount > 0 ? eyeOpennessSum / Double(eyeOpennessCount) : 0
            // Map the eye-aspect ratio into [0, 1]. Closed eyes hover around
            // 0.05; fully open around 0.30. Clamp + rescale.
            let eyeScore = max(0.0, min(1.0, (meanEye - 0.05) / 0.25))

            // Vision's face capture quality is already in [0, 1] when present.
            let captureQuality: Double
            if !qualityObservations.isEmpty {
                let qualities = qualityObservations.compactMap { Double($0.faceCaptureQuality ?? 0) }
                captureQuality = qualities.reduce(0, +) / Double(max(qualities.count, 1))
            } else {
                captureQuality = 0.5  // neutral if Vision didn't report
            }

            // Weighted combination — Vision's holistic face capture quality
            // (sharpness, lighting, expression all baked in) now leads; eye
            // openness is a minor factor so the best OVERALL shot wins rather
            // than whichever frame merely has the widest-open eyes.
            let smileBonus = smileLikely ? 0.05 : 0.0
            let score = min(1.0, 0.35 * eyeScore + 0.65 * captureQuality + smileBonus)

            continuation.resume(returning: Result(
                score: score,
                faceCount: observations.count,
                meanEyeOpenness: meanEye
            ))
        }
    }

    // MARK: - Geometry helpers

    /// Approximates eye openness via the aspect ratio of the eye-landmark
    /// polygon. Higher = wider open.
    private static func eyeAspect(of points: [CGPoint]) -> Double {
        guard points.count >= 4 else { return 0 }
        let xs = points.map { $0.x }
        let ys = points.map { $0.y }
        let width  = (xs.max() ?? 0) - (xs.min() ?? 0)
        let height = (ys.max() ?? 0) - (ys.min() ?? 0)
        guard width > 0 else { return 0 }
        return Double(height / width)
    }

    /// Rough smile detector: if the outer mouth corners are higher (smaller y
    /// in image-space — Vision normalised coords) than the mouth midpoint, the
    /// lips are curling upward.
    private static func isLikelySmile(_ points: [CGPoint]) -> Bool {
        guard points.count >= 6 else { return false }
        let sorted = points.sorted { $0.x < $1.x }
        let leftCorner  = sorted.first!
        let rightCorner = sorted.last!
        // Middle landmarks describe the upper/lower lip curve; take the average y.
        let middle = sorted.dropFirst().dropLast()
        let midY = middle.map { Double($0.y) }.reduce(0, +) / Double(max(middle.count, 1))
        let cornerY = (Double(leftCorner.y) + Double(rightCorner.y)) / 2
        // Vision normalised coords use y-up, so a smile has corners *above* (greater y) the mid.
        return cornerY > midY + 0.005
    }
}
