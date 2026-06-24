import Foundation

enum KeychainHelper {

    /// Removes plaintext files written by the old file-based implementation.
    /// Now performs a best-effort overwrite of the file contents with zeros
    /// before unlinking — APFS doesn't guarantee in-place writes, but this
    /// reduces the surface for residual plaintext recovery.
    /// Safe to call on every launch — no-op when the directory is already gone.
    static func deleteLegacyFileStorage() {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = base.appendingPathComponent("Keys", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }

        if let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for name in contents {
                let url = dir.appendingPathComponent(name)
                wipeFile(at: url)
            }
        }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Best-effort defense-in-depth: overwrite file content with zeros in place
    /// before removing, so a casual undelete tool is less likely to recover
    /// plaintext. This is NOT a guaranteed secure erase: on copy-on-write
    /// filesystems (APFS) the overwrite may land in freshly allocated blocks,
    /// and SSD wear-leveling can leave the original blocks physically intact.
    /// Treat it as harm reduction, not a secure-wipe guarantee.
    private static func wipeFile(at url: URL) {
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int),
           size > 0, size < 1_048_576 {  // 1 MB cap; legitimate key files are <1 KB
            let zeros = Data(count: size)
            // Write WITHOUT .atomic so the zeros go to the existing file in place,
            // rather than to a temp file that's renamed over the original (which
            // would leave the original plaintext blocks untouched).
            try? zeros.write(to: url)
        }
        try? FileManager.default.removeItem(at: url)
    }
}
