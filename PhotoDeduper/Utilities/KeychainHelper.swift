import Foundation
import Security

enum KeychainHelper {

    /// Hard caps on what we accept into the Keychain. The longest API key in
    /// any provider we support is ~108 bytes; 4 KB leaves headroom for future
    /// providers without giving an attacker an unbounded write surface.
    private static let maxKeyBytes = 4096

    private static let service = Bundle.main.bundleIdentifier ?? "com.photodeduper.app"

    static func save(key: String, value: String) {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        guard let data = cleaned.data(using: .utf8), data.count <= maxKeyBytes else { return }
        delete(key: key)                    // delete-then-add pattern avoids duplicate-item error
        let query: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    service,
            kSecAttrAccount:    key,
            kSecValueData:      data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func retrieve(key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns true iff a non-empty value is stored for `key`. Useful for UI
    /// that wants to show "key configured" without reading the value into
    /// memory. The Keychain query itself doesn't copy the value bytes when
    /// `kSecReturnData` is false.
    static func has(key: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData:  false,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete(key: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

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

    /// Defense-in-depth: overwrite file content with zeros before removing,
    /// so a casual undelete tool doesn't recover plaintext. Not a substitute
    /// for actual secure-erase on a copy-on-write filesystem, but reduces
    /// the worst-case footprint.
    private static func wipeFile(at url: URL) {
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int),
           size > 0, size < 1_048_576 {  // 1 MB cap; legitimate key files are <1 KB
            let zeros = Data(count: size)
            try? zeros.write(to: url, options: .atomic)
        }
        try? FileManager.default.removeItem(at: url)
    }
}
