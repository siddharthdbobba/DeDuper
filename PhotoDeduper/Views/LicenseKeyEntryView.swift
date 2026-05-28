#if DIRECT_DISTRIBUTION
import SwiftUI

/// Sheet for entering and activating a LemonSqueezy license key.
/// Only compiled in DIRECT_DISTRIBUTION builds.
struct LicenseKeyEntryView: View {

    @ObservedObject private var entitlements = EntitlementStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var licenseKey = ""
    @State private var errorMessage: String? = nil
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer(minLength: 4)

                // Icon + heading
                VStack(spacing: 10) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)

                    Text("Enter License Key")
                        .font(.title2.bold())

                    Text("Check your purchase confirmation email\nfor your license key.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Input
                VStack(alignment: .leading, spacing: 6) {
                    TextField("XXXX-XXXX-XXXX-XXXX", text: $licenseKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .focused($fieldFocused)
                        .onSubmit { Task { await activate() } }
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif

                    if let error = errorMessage {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal)

                // Activate button
                Button {
                    Task { await activate() }
                } label: {
                    HStack {
                        if entitlements.isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                                .padding(.trailing, 4)
                        }
                        Text("Activate License")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(trimmedKey.isEmpty || entitlements.isLoading)
                .padding(.horizontal)

                // Help link
                Button("Didn't receive a key? Contact support") {
                    #if os(macOS)
                    NSWorkspace.shared.open(URL(string: "mailto:support@yourapp.com")!)
                    #else
                    UIApplication.shared.open(URL(string: "mailto:support@yourapp.com")!)
                    #endif
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer(minLength: 4)
            }
            .padding()
            .navigationTitle("License Key")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 340)
        #endif
        .onAppear { fieldFocused = true }
    }

    private var trimmedKey: String {
        licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func activate() async {
        guard !trimmedKey.isEmpty else { return }
        errorMessage = nil
        do {
            try await entitlements.activate(licenseKey: trimmedKey)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    LicenseKeyEntryView()
}
#endif
