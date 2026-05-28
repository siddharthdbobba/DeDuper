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
    let hashes: [UInt64]   // start, middle, end
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
        var hashes: [UInt64] = []
        for seconds in sampleTimes {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            do {
                let cg = try await generateCGImage(generator: generator, at: time)
                if let hash = grouper.differenceHash(cg) {
                    hashes.append(hash)
                }
            } catch {
                continue
            }
        }
        guard hashes.count >= 2 else { return nil }
        return VideoFingerprint(item: item, hashes: hashes, duration: duration)
    }

    /// Considers two video fingerprints to be duplicates when every available
    /// keyframe hash is within `threshold` Hamming bits AND their durations are
    /// within 10% of each other.
    static func areSimilar(_ a: VideoFingerprint, _ b: VideoFingerprint, threshold: Int = 12) -> Bool {
        let longer = max(a.duration, b.duration)
        guard longer > 0 else { return false }
        let durationDelta = abs(a.duration - b.duration) / longer
        guard durationDelta < 0.10 else { return false }

        let pairs = min(a.hashes.count, b.hashes.count)
        guard pairs > 0 else { return false }
        let grouper = SimilarityGrouper()
        for i in 0..<pairs {
            if grouper.hammingDistance(a.hashes[i], b.hashes[i]) >= threshold {
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

