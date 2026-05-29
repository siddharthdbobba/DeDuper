import SwiftUI

@main
struct PhotoDeduperApp: App {
    init() {
        // Register defaults once at launch, before any window/scan/Settings
        // code can read them. .bool(forKey:) returns false for unset keys, so
        // keys read via .bool() (e.g. crossFormatEnabled) must be seeded here
        // to match the intended defaults. register(defaults:) only affects keys
        // with no explicitly-set value, so existing users keep their settings.
        UserDefaults.standard.register(defaults: [
            "crossFormatEnabled": true,
            "timeWindow": 30.0,        // read as Double
            "pHashThreshold": 20,      // read as Int
            "closeCallThreshold": 15.0, // read as Double
            "holdForReview": false,
            "autoReviewEnabled": true   // preserves prior default (was registered true at launch)
        ])
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
