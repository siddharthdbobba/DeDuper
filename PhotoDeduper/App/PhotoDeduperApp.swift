import SwiftUI

@main
struct PhotoDeduperApp: App {
    init() {
        // Register defaults once at launch, before any window/scan/Settings
        // code can read them. See AppDefaults for the single source of truth
        // on keys and default values. register(defaults:) only affects keys
        // with no explicitly-set value, so existing users keep their settings.
        UserDefaults.standard.register(defaults: AppDefaults.registration)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
#if os(macOS)
                .frame(minWidth: 1000, minHeight: 680)
#endif
                .task {
                    KeychainHelper.deleteLegacyFileStorage()
                }
        }
#if os(macOS)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
#endif
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Centralized, typed access to the app's `UserDefaults`-backed settings.
/// Keeps the storage keys and their default values in one place so the
/// settings UI (`SettingsView`) and the scan pipeline (`ReviewViewModel`)
/// can't silently disagree on a key name or a default.
enum AppDefaults {
    private static let store = UserDefaults.standard

    private enum Key {
        static let timeWindow = "timeWindow"
        static let pHashThreshold = "pHashThreshold"
        static let closeCallThreshold = "closeCallThreshold"
        static let scanVideosToo = "scanVideosToo"
        static let holdForReview = "holdForReview"
        static let protectedAlbumIDs = "protectedAlbumIDs"
        static let reviewAlbumLocalID = "reviewAlbumLocalID"
    }

    // Default values — single source of truth, also registered at launch so
    // `.object(forKey:)` reads return sane values on first run.
    static let timeWindowDefault = 30.0
    static let pHashThresholdDefault = 20
    static let closeCallThresholdDefault = 15.0
    static let holdForReviewDefault = false

    /// Registered with `UserDefaults` at launch. `register(defaults:)` only
    /// affects keys with no explicitly-set value, so existing users keep theirs.
    static let registration: [String: Any] = [
        Key.timeWindow: timeWindowDefault,
        Key.pHashThreshold: pHashThresholdDefault,
        Key.closeCallThreshold: closeCallThresholdDefault,
        Key.holdForReview: holdForReviewDefault,
    ]

    /// Seconds; photos taken within this window are grouped as candidates.
    static var timeWindow: Double {
        get { store.object(forKey: Key.timeWindow) as? Double ?? timeWindowDefault }
        set { store.set(newValue, forKey: Key.timeWindow) }
    }

    /// Max Hamming distance (bits) for visual similarity (dHash).
    static var pHashThreshold: Int {
        get { store.object(forKey: Key.pHashThreshold) as? Int ?? pHashThresholdDefault }
        set { store.set(newValue, forKey: Key.pHashThreshold) }
    }

    /// Percent score gap below which the on-device resolver breaks a tie.
    static var closeCallThreshold: Double {
        get { store.object(forKey: Key.closeCallThreshold) as? Double ?? closeCallThresholdDefault }
        set { store.set(newValue, forKey: Key.closeCallThreshold) }
    }

    /// Whether videos are included in scans.
    static var scanVideosToo: Bool {
        get { store.bool(forKey: Key.scanVideosToo) }
        set { store.set(newValue, forKey: Key.scanVideosToo) }
    }

    /// Whether deletions are held for a final review pass instead of deleted directly.
    static var holdForReview: Bool {
        get { store.bool(forKey: Key.holdForReview) }
        set { store.set(newValue, forKey: Key.holdForReview) }
    }

    /// Local identifiers of albums whose photos are protected from deletion.
    static var protectedAlbumIDs: [String] {
        get { store.array(forKey: Key.protectedAlbumIDs) as? [String] ?? [] }
        set { store.set(newValue, forKey: Key.protectedAlbumIDs) }
    }

    /// Local identifier of the auto-created "PhotoDeduper Review" album. Internal
    /// bookkeeping (not a user setting), so it has no registered default — `nil`
    /// means the album hasn't been created yet and must be (re)created.
    static var reviewAlbumLocalID: String? {
        get { store.string(forKey: Key.reviewAlbumLocalID) }
        set { store.set(newValue, forKey: Key.reviewAlbumLocalID) }
    }
}
