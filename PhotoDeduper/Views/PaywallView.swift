import SwiftUI
import StoreKit

/// Paywall sheet shown when a user tries to use a premium AI feature
/// without having purchased DeDuper Premium.
///
/// Compiles to two different CTAs depending on the build:
///   - App Store build:       StoreKit purchase + Restore Purchases
///   - Direct distribution:   "Buy Now" (opens browser) + "Enter License Key"
struct PaywallView: View {
    @ObservedObject private var entitlements = EntitlementStore.shared
    @Environment(\.dismiss) private var dismiss

    // App Store error state
    @State private var purchaseError: String? = nil

    // Direct distribution
    @State private var showLicenseEntry = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    Spacer(minLength: 8)

                    // MARK: - Icon + title
                    VStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 64))
                            .foregroundStyle(.blue)

                        Text("DeDuper Premium")
                            .font(.largeTitle.bold())

                        Text("One-time purchase. No subscription.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // MARK: - Feature list
                    VStack(alignment: .leading, spacing: 14) {
                        featureRow(icon: "wand.and.stars", color: .blue,
                                   title: "Bundled AI Review",
                                   description: "No API key required — powered by GPT-4.1 mini")
                        featureRow(icon: "key.fill", color: .orange,
                                   title: "Bring Your Own Key",
                                   description: "Use your own Claude, ChatGPT, or Groq API key")
                        featureRow(icon: "sparkles.rectangle.stack", color: .purple,
                                   title: "Review All",
                                   description: "Batch AI review across every close-call group at once")
                        featureRow(icon: "bolt.fill", color: .yellow,
                                   title: "Auto-Review",
                                   description: "AI automatically picks the best shot during every scan")
                    }
                    .padding(.horizontal, 8)

                    // MARK: - Buy / activate buttons
                    #if DIRECT_DISTRIBUTION
                    directCTASection
                    #else
                    appStoreCTASection
                    #endif

                    Spacer(minLength: 8)
                }
                .padding()
            }
            .navigationTitle("Unlock Premium")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                }
            }
            #if DIRECT_DISTRIBUTION
            .sheet(isPresented: $showLicenseEntry) {
                LicenseKeyEntryView()
                    .onDisappear {
                        if entitlements.hasPremium { dismiss() }
                    }
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 560)
        #endif
    }

    // MARK: - Direct distribution CTA

    #if DIRECT_DISTRIBUTION
    private var directCTASection: some View {
        VStack(spacing: 14) {
            // Primary: open checkout in browser
            Button {
                #if os(macOS)
                NSWorkspace.shared.open(AppConfig.lemonSqueezyCheckoutURL)
                #else
                UIApplication.shared.open(AppConfig.lemonSqueezyCheckoutURL)
                #endif
            } label: {
                Text("Buy Now — \(AppConfig.directPrice)")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            // Secondary: already bought
            Button("I already have a license key") {
                showLicenseEntry = true
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Text("One-time payment. No subscription. Installs on up to 3 Macs.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

        }
    }
    #endif

    // MARK: - App Store CTA

    #if !DIRECT_DISTRIBUTION
    private var appStoreCTASection: some View {
        VStack(spacing: 12) {
            if entitlements.product == nil && !entitlements.isLoading {
                VStack(spacing: 8) {
                    Label("Coming Soon to the Mac App Store", systemImage: "clock")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    Text("Premium is not yet available for purchase. Check back soon.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                if let error = purchaseError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task {
                        purchaseError = nil
                        do {
                            try await entitlements.purchase()
                            if entitlements.hasPremium { dismiss() }
                        } catch {
                            purchaseError = "Purchase failed: \(error.localizedDescription)"
                        }
                    }
                } label: {
                    HStack {
                        if entitlements.isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                                .padding(.trailing, 4)
                        }
                        Text(appStoreBuyTitle)
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(entitlements.isLoading || entitlements.product == nil)

                Button("Restore Purchases") {
                    Task {
                        await entitlements.restore()
                        if entitlements.hasPremium { dismiss() }
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .disabled(entitlements.isLoading)

                Text("Payment charged to your Apple ID account. Non-consumable; one-time purchase.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

        }
    }

    private var appStoreBuyTitle: String {
        if let price = entitlements.product?.displayPrice {
            return "Unlock Premium — \(price)"
        }
        return "Unlock Premium"
    }
    #endif

    // MARK: - Shared helpers

    @ViewBuilder
    private func featureRow(icon: String, color: Color, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 28)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    PaywallView()
}
