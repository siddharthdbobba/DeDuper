import StoreKit

/// Manages premium entitlement state for DeDuper.
///
/// Compiles to one of two implementations depending on the build:
///
/// **App Store build** (default):
///   Uses StoreKit 2 — non-consumable one-time purchase via Apple.
///   `purchase()` initiates the App Store sheet.
///   `restore()` syncs receipts after reinstall.
///
/// **Direct distribution build** (`DIRECT_DISTRIBUTION` flag):
///   Uses LemonSqueezy license keys — no App Store involved.
///   `activate(licenseKey:)` validates and stores the key.
///   `deactivateLicense()` removes this machine's activation.
///
/// In both builds `hasPremium` is the single source of truth consumed by all views.
@MainActor
final class EntitlementStore: ObservableObject {

    static let shared = EntitlementStore()

    /// Whether the user has unlocked DeDuper Premium.
    @Published private(set) var hasPremium: Bool = false

    /// StoreKit product (App Store builds only — always nil in direct builds).
    @Published private(set) var product: Product? = nil

    /// True while a purchase / restore / activation is in-flight.
    @Published private(set) var isLoading: Bool = false

    private let premiumProductID = "com.photodeduper.app.premium"
    private var updateListenerTask: Task<Void, Never>?

    private init() {
        #if !DIRECT_DISTRIBUTION
        updateListenerTask = listenForTransactions()
        #endif
        Task { await refresh() }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    // MARK: - App Store: Purchase & Restore

    #if !DIRECT_DISTRIBUTION

    /// Initiates the App Store purchase flow.
    func purchase() async throws {
        guard let product else { return }
        isLoading = true
        defer { isLoading = false }

        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try verification.payloadValue
            await transaction.finish()
            hasPremium = true
        case .pending, .userCancelled:
            break
        @unknown default:
            break
        }
    }

    /// Syncs App Store receipts. Call from "Restore Purchases".
    func restore() async {
        isLoading = true
        defer { isLoading = false }
        try? await AppStore.sync()
        await refresh()
    }

    #endif

    // MARK: - Direct Distribution: License Key

    #if DIRECT_DISTRIBUTION

    /// Activates a LemonSqueezy license key for this machine.
    /// Stores the key in Keychain and sets `hasPremium = true` on success.
    func activate(licenseKey: String) async throws {
        isLoading = true
        defer { isLoading = false }
        try await LemonSqueezyManager.shared.activate(licenseKey: licenseKey)
        hasPremium = true
    }

    /// Deactivates this machine's license, clears Keychain, and sets `hasPremium = false`.
    func deactivateLicense() async {
        isLoading = true
        defer { isLoading = false }
        try? await LemonSqueezyManager.shared.deactivate()
        hasPremium = false
    }

    #endif

    // MARK: - Internal

    private func refresh() async {
        #if DIRECT_DISTRIBUTION
        hasPremium = await LemonSqueezyManager.shared.validate()
        #if DEBUG
        print("[EntitlementStore] direct refresh — hasPremium=\(hasPremium)")
        #endif
        #else
        do {
            let products = try await Product.products(for: [premiumProductID])
            #if DEBUG
            print("[EntitlementStore] products fetched: \(products.map(\.id))")
            #endif
            product = products.first
        } catch {
            #if DEBUG
            print("[EntitlementStore] Product.products error: \(error)")
            #endif
        }

        var foundPremium = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result, tx.productID == premiumProductID {
                foundPremium = true
                break
            }
        }
        hasPremium = foundPremium
        #if DEBUG
        print("[EntitlementStore] refresh done — product=\(product?.id ?? "nil") hasPremium=\(hasPremium)")
        #endif
        #endif
    }

    #if !DIRECT_DISTRIBUTION
    private func listenForTransactions() -> Task<Void, Never> {
        Task(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let tx) = result, tx.productID == self.premiumProductID {
                    await tx.finish()
                    await MainActor.run { self.hasPremium = true }
                }
            }
        }
    }
    #endif
}
