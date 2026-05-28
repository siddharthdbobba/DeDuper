import Foundation

/// Persistent record of every deletion the user has confirmed. Surfaces in the
/// session-stats UI and exports to CSV for users who want a paper trail.
///
/// Entries are appended atomically to a JSON file inside Application Support.
/// The file is small (one line per deletion) and survives app relaunches.
struct AuditEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let photoID: String
    let filename: String?
    let estimatedBytes: Int64
    let groupSize: Int
    let aiProvider: String?
    let aiReason: String?
    let restored: Bool
}

@MainActor
final class AuditLogger {

    static let shared = AuditLogger()

    /// Soft cap. When the log exceeds this, the oldest entries are pruned to
    /// keep the file's parse cost bounded. A power user deleting hundreds of
    /// dupes per scan would otherwise eventually hit JSON-parse latency.
    private let maxEntries = 10_000

    private let fileURL: URL
    private let queue = DispatchQueue(label: "PhotoDeduper.AuditLogger", qos: .utility)

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("PhotoDeduper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("audit-log.json")
    }

    /// Appends an entry to the log. Returns the entry so the caller can hold
    /// onto its id if it wants to mark it `restored` later. When the log
    /// exceeds `maxEntries` the oldest entries are pruned so write/read cost
    /// stays bounded.
    @discardableResult
    func record(_ entry: AuditEntry) -> AuditEntry {
        batchRecord([entry])
        return entry
    }

    /// Appends all entries in one read-modify-write cycle. Prefer this over
    /// calling `record` in a loop to avoid O(n²) I/O for bulk deletions.
    func batchRecord(_ entries: [AuditEntry]) {
        guard !entries.isEmpty else { return }
        var all = readAll()
        all.append(contentsOf: entries)
        if all.count > maxEntries {
            all.removeFirst(all.count - maxEntries)
        }
        write(all)
    }

    /// Marks the given entries as restored. No-op for ids that aren't in the log.
    func markRestored(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var all = readAll()
        for i in all.indices where ids.contains(all[i].id) {
            all[i] = AuditEntry(
                id: all[i].id,
                timestamp: all[i].timestamp,
                photoID: all[i].photoID,
                filename: all[i].filename,
                estimatedBytes: all[i].estimatedBytes,
                groupSize: all[i].groupSize,
                aiProvider: all[i].aiProvider,
                aiReason: all[i].aiReason,
                restored: true
            )
        }
        write(all)
    }

    func readAll() -> [AuditEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder.iso8601.decode([AuditEntry].self, from: data)) ?? []
    }

    /// Returns only entries created during the current session, identified by
    /// timestamp >= `sessionStart`.
    func sessionEntries(since sessionStart: Date) -> [AuditEntry] {
        readAll().filter { $0.timestamp >= sessionStart && !$0.restored }
    }

    /// Writes a CSV representation of the log to the given URL.
    /// Throws on file-system errors.
    func exportCSV(to url: URL) throws {
        let all = readAll()
        let header = "timestamp,photoID,filename,estimatedBytes,groupSize,aiProvider,aiReason,restored\n"
        var body = header
        let isoFormatter = ISO8601DateFormatter()
        for entry in all {
            let cells = [
                csvEscape(isoFormatter.string(from: entry.timestamp)),
                csvEscape(entry.photoID),
                csvEscape(entry.filename ?? ""),
                String(entry.estimatedBytes),
                String(entry.groupSize),
                csvEscape(entry.aiProvider ?? ""),
                csvEscape(entry.aiReason ?? ""),
                entry.restored ? "yes" : "no",
            ]
            body += cells.joined(separator: ",") + "\n"
        }
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Total bytes recovered across all entries. Useful for the session-stats UI.
    func totalEstimatedBytes() -> Int64 {
        readAll().filter { !$0.restored }.map { $0.estimatedBytes }.reduce(0, +)
    }

    func totalDeletions() -> Int {
        readAll().filter { !$0.restored }.count
    }

    // MARK: - Private

    private func write(_ entries: [AuditEntry]) {
        guard let data = try? JSONEncoder.iso8601.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
        // Belt-and-suspenders even though Application Support is already
        // sandboxed to this app. Photo IDs can include file-system paths that
        // leak directory structure, so lock the log to owner-only.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
        )
        var url = fileURL
        var res = URLResourceValues()
        res.isExcludedFromBackup = true
        try? url.setResourceValues(res)
    }

    private func csvEscape(_ s: String) -> String {
        // Always quote strings that Excel/Numbers/Sheets would interpret as
        // formulas (=, +, -, @, | prefixes), or that contain CSV delimiters.
        let formulaStarters: Set<Character> = ["=", "+", "-", "@", "|", "\t"]
        let needsQuoting = s.isEmpty == false && formulaStarters.contains(s.first!)
            || s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r")
        if needsQuoting {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}

extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()
}

extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()
}
