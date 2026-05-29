import Foundation
import CoreGraphics
import AVFoundation
import Photos

/// Computes a perceptual fingerprint for a video by hashing three sampled
/// keyframes (start, middle, end). Two videos are considered identical when
/// every keyframe hash matches within the configured Hamming threshold.
///
/// Designed to be cheap enough to run on every video in a Photos library —
/// keyframe extraction is the slow part (~50–200 ms per video), but hashing
/// itself is O(64).
struct VideoFingerprint {
    let item: PhotoItem
    /// Keyframe hashes keyed by sampling position (0 = start, 1 = middle,
    /// 2 = end). A position is absent when that keyframe failed to extract,
    /// so positions stay aligned across fingerprints even when some frames
    /// are missing. Compared position-by-position in `areSimilar`.
    let hashes: [Int: UInt64]
    let duration: Double
}

struct VideoHasher {

    /// Generates a `VideoFingerprint` for the given video item. Returns nil if
    /// keyframe extraction failed (corrupt file, unsupported codec).
    ///
    /// Manages the security-scoped resource lifecycle internally for file URLs
    /// so callers don't have to remember to stop it after each call.
    static func fingerprint(for item: PhotoItem) async -> VideoFingerprint? {
        guard item.isVideo else { return nil }

        // For file URLs, open the security scope here and close it on exit.
        // loadAsset assumes the scope is already active for file URLs.
        var fileURLToRelease: URL?
        defer {
            if let url = fileURLToRelease {
                url.stopAccessingSecurityScopedResource()
            }
        }
        if case .fileURL(let url) = item.source {
            guard url.startAccessingSecurityScopedResource() else { return nil }
            fileURLToRelease = url
        }

        let asset = await loadAsset(for: item)
        guard let asset else { return nil }

        let duration: Double
        do {
            let cmTime = try await asset.load(.duration)
            duration = cmTime.seconds.isFinite ? cmTime.seconds : 0
        } catch {
            duration = 0
        }
        guard duration > 0 else { return nil }

        // Three sample points: 10% in, 50% in, 90% in. Avoids the very first
        // frame (often black) and the very last (sometimes the wrap-up of a fade).
        let sampleTimes = [duration * 0.1, duration * 0.5, duration * 0.9]
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 64, height: 64)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 0.5, preferredTimescale: 600)

        let grouper = SimilarityGrouper()
        // Key each hash by its sampling position so a failed/missing frame
        // leaves a gap rather than shifting later frames into earlier slots.
        var hashes: [Int: UInt64] = [:]
        for (position, seconds) in sampleTimes.enumerated() {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            do {
                let cg = try await generateCGImage(generator: generator, at: time)
                if let hash = grouper.differenceHash(cg) {
                    hashes[position] = hash
                }
            } catch {
                continue
            }
        }
        guard hashes.count >= 2 else { return nil }
        return VideoFingerprint(item: item, hashes: hashes, duration: duration)
    }

    /// Considers two video fingerprints to be duplicates when every keyframe
    /// hash sampled at a *shared* position is within `threshold` Hamming bits
    /// AND their durations are within 10% of each other. Positions present in
    /// only one fingerprint are ignored; if the two share no positions at all
    /// they are conservatively treated as not-similar.
    static func areSimilar(_ a: VideoFingerprint, _ b: VideoFingerprint, threshold: Int = 12) -> Bool {
        let longer = max(a.duration, b.duration)
        guard longer > 0 else { return false }
        let durationDelta = abs(a.duration - b.duration) / longer
        guard durationDelta < 0.10 else { return false }

        // Compare only keyframes sampled at the same position; a hash at
        // position 1 (middle) is never compared against position 0 (start).
        let sharedPositions = Set(a.hashes.keys).intersection(b.hashes.keys)
        guard !sharedPositions.isEmpty else { return false }
        let grouper = SimilarityGrouper()
        for position in sharedPositions {
            guard let ha = a.hashes[position], let hb = b.hashes[position] else { continue }
            if grouper.hammingDistance(ha, hb) >= threshold {
                return false
            }
        }
        return true
    }

    // MARK: - Private

    private static func loadAsset(for item: PhotoItem) async -> AVAsset? {
        switch item.source {
        case .fileURL(let url):
            return AVURLAsset(url: url)   // scope already started by fingerprint
        case .asset(let phAsset):
            // PHCachingImageManager would be heavier than we need here; the
            // standard imageManager.requestAVAsset path is async and gives us
            // the same AVAsset under the hood.
            return await withCheckedContinuation { continuation in
                let options = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .fastFormat
                var resumed = false
                PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { asset, _, _ in
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: asset)
                }
            }
        }
    }

    private static func generateCGImage(generator: AVAssetImageGenerator, at time: CMTime) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, result, error in
                switch result {
                case .succeeded:
                    if let cgImage {
                        continuation.resume(returning: cgImage)
                    } else {
                        continuation.resume(throwing: NSError(domain: "VideoHasher", code: -1))
                    }
                case .failed, .cancelled:
                    continuation.resume(throwing: error ?? NSError(domain: "VideoHasher", code: -2))
                @unknown default:
                    continuation.resume(throwing: NSError(domain: "VideoHasher", code: -3))
                }
            }
        }
    }
}

