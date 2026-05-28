import SwiftUI

@main
struct PhotoDeduperApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
#if os(macOS)
                .frame(minWidth: 1000, minHeight: 680)
#endif
                .task {
                    UserDefaults.standard.register(defaults: ["autoReviewEnabled": true])
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
