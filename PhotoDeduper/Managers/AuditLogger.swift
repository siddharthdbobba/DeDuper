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
    /// Why the keeper was chosen (on-device close-call explanation), if any.
    let reason: String?
    let restored: Bool
}

@MainActor
final class AuditLogger {

    static let shared = AuditLogger()

    /// Soft cap. When the log exceeds this, the oldest entries are pruned to
    /// keep the file's parse cost bounded. A power user deleting hundreds of
    /// dupes per scan would otherwise eventually hit JSON-parse latency.
    ///
    /// `nonisolated` so the off-main serial-queue closures (below) can read it
    /// without hopping back to the main actor.
    private nonisolated let maxEntries = 10_000

    /// `nonisolated`: an immutable, Sendable `URL`. The background I/O helpers
    /// read it off the main actor, so it must not be main-actor-isolated.
    private nonisolated let fileURL: URL

    /// Serial queue that owns all disk read-modify-write cycles. Keeping every
    /// mutation on this single queue moves the file I/O off the main thread and
    /// guarantees append order without an explicit lock.
    private nonisolated let queue = DispatchQueue(label: "PhotoDeduper.AuditLogger", qos: .utility)

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
    ///
    /// The id is supplied by the caller, so we can return synchronously and let
    /// the actual disk write happen off-main (see `batchRecord`).
    @discardableResult
    func record(_ entry: AuditEntry) -> AuditEntry {
        batchRecord([entry])
        return entry
    }

    /// Appends all entries in one read-modify-write cycle. Prefer this over
    /// calling `record` in a loop to avoid O(n²) I/O for bulk deletions.
    ///
    /// Returns immediately: the read-decode-encode-write happens on `queue`, so
    /// it never blocks the main thread. Callers stay fire-and-forget and the
    /// serial queue preserves append order. Only Sendable value types
    /// (`entries`, `fileURL`, `maxEntries`) are captured into the closure — `self`
    /// is never captured, so no main-actor-isolated state crosses the boundary.
    func batchRecord(_ entries: [AuditEntry]) {
        guard !entries.isEmpty else { return }
        let fileURL = self.fileURL
        let maxEntries = self.maxEntries
        queue.async {
            var all = Self.readAll(from: fileURL)
            all.append(contentsOf: entries)
            if all.count > maxEntries {
                all.removeFirst(all.count - maxEntries)
            }
            Self.write(all, to: fileURL)
        }
    }

    /// Marks the given entries as restored. No-op for ids that aren't in the log.
    ///
    /// Like `batchRecord`, the read-modify-write runs on `queue` so it stays off
    /// the main thread and serialized after any in-flight append. Only the
    /// Sendable `ids` and `fileURL` values are captured; `self` is not.
    func markRestored(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let fileURL = self.fileURL
        queue.async {
            var all = Self.readAll(from: fileURL)
            for i in all.indices where ids.contains(all[i].id) {
                all[i] = AuditEntry(
                    id: all[i].id,
                    timestamp: all[i].timestamp,
                    photoID: all[i].photoID,
                    filename: all[i].filename,
                    estimatedBytes: all[i].estimatedBytes,
                    groupSize: all[i].groupSize,
                    reason: all[i].reason,
                    restored: true
                )
            }
            Self.write(all, to: fileURL)
        }
    }

    /// Synchronous read used by the read-only query methods below. The actual
    /// decode is in a `nonisolated static` helper so the background write
    /// closures can reuse it without touching main-actor state.
    nonisolated func readAll() -> [AuditEntry] {
        // Deliberately read WITHOUT queue.sync: a query that coincides with a
        // bulk delete's pending writes must not block the main thread waiting on
        // them — that main-thread stall is exactly what P6 removed. Writes are
        // .atomic so a read never tears; the only cost is that a read racing an
        // in-flight write may be momentarily stale, which is benign here (the undo
        // bookkeeping read runs well after its write, and the stats are advisory).
        Self.readAll(from: fileURL)
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
        let header = "timestamp,photoID,filename,estimatedBytes,groupSize,reason,restored\n"
        var body = header
        let isoFormatter = ISO8601DateFormatter()
        for entry in all {
            let cells = [
                csvEscape(isoFormatter.string(from: entry.timestamp)),
                csvEscape(entry.photoID),
                csvEscape(entry.filename ?? ""),
                String(entry.estimatedBytes),
                String(entry.groupSize),
                csvEscape(entry.reason ?? ""),
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

    /// `nonisolated static` so it can run on `queue` (off the main actor). It
    /// touches only the file system and value types, never main-actor state.
    private nonisolated static func readAll(from fileURL: URL) -> [AuditEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder.iso8601.decode([AuditEntry].self, from: data)) ?? []
    }

    /// `nonisolated static` for the same reason as `readAll(from:)`: the disk
    /// write runs on `queue`, so it must not depend on main-actor isolation.
    private nonisolated static func write(_ entries: [AuditEntry], to fileURL: URL) {
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
        // Quoting alone does NOT stop formula injection: Excel/Numbers/Sheets
        // still evaluate a cell that begins with =, +, -, @ (or |) even when it
        // is wrapped in quotes. Neutralize it by prefixing a single quote so the
        // spreadsheet treats the whole cell as literal text. We check the
        // whitespace-trimmed value so a leading space can't hide the starter.
        let formulaStarters: Set<Character> = ["=", "+", "-", "@", "|", "\t"]
        var value = s
        if let firstNonSpace = value.trimmingCharacters(in: .whitespaces).first,
           formulaStarters.contains(firstNonSpace) {
            value = "'" + value
        }
        // Quote cells that contain CSV delimiters (and any we just prefixed, so
        // the leading quote is preserved verbatim). Embedded quotes are doubled.
        let needsQuoting = value != s
            || value.contains(",") || value.contains("\"")
            || value.contains("\n") || value.contains("\r")
        if needsQuoting {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
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
