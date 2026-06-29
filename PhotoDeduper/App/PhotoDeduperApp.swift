import SwiftUI
#if os(macOS)
import AppKit

/// Closes the app when its single window is closed.
///
/// PhotoDeduper is a single-window utility (`WindowGroup` with the `File ▸ New`
/// command removed), so once the user closes the window there is no menu item or
/// Dock affordance to bring it back — App Review flagged exactly this under
/// Guideline 4 (Design). Per Apple's guidance for single-window apps, the right
/// behavior is to terminate when the last window closes. Settings live in
/// `UserDefaults` (already persisted) and the in-progress review is intentionally
/// in-memory only, so there is nothing else to save on the way out.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#endif

@main
struct PhotoDeduperApp: App {
#if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
#endif

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
        static let reviewSortNewestFirst = "reviewSortNewestFirst"
        static let confirmBeforeDelete = "confirmBeforeDelete"
        static let hasSeenDeleteInfo = "hasSeenDeleteInfo"
        static let protectedAlbumIDs = "protectedAlbumIDs"
        static let reviewAlbumLocalID = "reviewAlbumLocalID"
    }

    // Default values — single source of truth, also registered at launch so
    // `.object(forKey:)` reads return sane values on first run.
    // (30, 15, 15) matches the "Balanced" preset (see Sensitivity.thresholds),
    // so fresh installs show "Balanced" in Settings rather than "Custom".
    static let timeWindowDefault = 30.0
    static let pHashThresholdDefault = 15
    static let closeCallThresholdDefault = 15.0
    static let holdForReviewDefault = false
    static let reviewSortNewestFirstDefault = false
    // Default OFF — pressing Delete removes photos immediately (they still go to
    // Recently Deleted and Cmd+Z undoes). Users who want the extra prompt can
    // re-enable it via Settings → Behavior → "Confirm before delete".
    static let confirmBeforeDeleteDefault = false

    /// Registered with `UserDefaults` at launch. `register(defaults:)` only
    /// affects keys with no explicitly-set value, so existing users keep theirs.
    static let registration: [String: Any] = [
        Key.timeWindow: timeWindowDefault,
        Key.pHashThreshold: pHashThresholdDefault,
        Key.closeCallThreshold: closeCallThresholdDefault,
        Key.holdForReview: holdForReviewDefault,
        Key.reviewSortNewestFirst: reviewSortNewestFirstDefault,
        Key.confirmBeforeDelete: confirmBeforeDeleteDefault,
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

    /// Whether duplicate groups are reviewed newest-first instead of oldest-first.
    static var reviewSortNewestFirst: Bool {
        get { store.bool(forKey: Key.reviewSortNewestFirst) }
        set { store.set(newValue, forKey: Key.reviewSortNewestFirst) }
    }

    /// Whether to show a confirmation dialog before deleting.
    static var confirmBeforeDelete: Bool {
        get { store.object(forKey: Key.confirmBeforeDelete) as? Bool ?? confirmBeforeDeleteDefault }
        set { store.set(newValue, forKey: Key.confirmBeforeDelete) }
    }

    /// Whether the user has ever seen the one-time educational delete explainer.
    /// Latched true the first time they confirm a frictionless flush (see
    /// ReviewView.deleteButton). Internal bookkeeping, not a user-facing setting,
    /// so it has no registered default — `false` (the bool default) correctly
    /// means "not yet shown", and existing users start fresh and see it once.
    static var hasSeenDeleteInfo: Bool {
        get { store.bool(forKey: Key.hasSeenDeleteInfo) }
        set { store.set(newValue, forKey: Key.hasSeenDeleteInfo) }
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
