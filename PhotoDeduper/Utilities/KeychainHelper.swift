import Foundation

/// Stores API keys as files in the app's sandboxed Application Support directory.
/// The sandbox prevents other apps from accessing these files; permissions are set to
/// owner-read/write only (0600) and files are excluded from backups.
enum KeychainHelper {

    private static let keysDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Keys", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        return dir
    }()

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let url = keysDir.appendingPathComponent(key)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var mutable = url
        var res = URLResourceValues()
        res.isExcludedFromBackup = true
        try? mutable.setResourceValues(res)
    }

    static func retrieve(key: String) -> String? {
        let url = keysDir.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let url = keysDir.appendingPathComponent(key)
        try? FileManager.default.removeItem(at: url)
    }
}
