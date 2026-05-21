import SwiftUI

struct SettingsView: View {
    @State private var claudeKey: String = KeychainHelper.retrieve(key: "claude_api_key") ?? ""
    @State private var openAIKey: String = KeychainHelper.retrieve(key: "openai_api_key") ?? ""
    @State private var groqKey: String = KeychainHelper.retrieve(key: "groq_api_key") ?? ""
    @State private var groqModel: String = {
        // Same migration logic GroqReviewer uses — keep the displayed value in sync
        // so the Settings field doesn't show a stale, decommissioned model name.
        let deprecated: Set<String> = [
            "llama-3.2-11b-vision-preview",
            "llama-3.2-90b-vision-preview",
        ]
        let saved = UserDefaults.standard.string(forKey: "groqModel")
        if let saved, !saved.isEmpty, !deprecated.contains(saved) { return saved }
        return "meta-llama/llama-4-scout-17b-16e-instruct"
    }()
    @State private var isPaidUser: Bool = UserDefaults.standard.bool(forKey: "isPaidUser")
    @State private var timeWindow: Double = UserDefaults.standard.object(forKey: "timeWindow") as? Double ?? 30
    @State private var hashThreshold: Double = Double(UserDefaults.standard.object(forKey: "pHashThreshold") as? Int ?? 15)
    @State private var closeCallThreshold: Double = UserDefaults.standard.object(forKey: "closeCallThreshold") as? Double ?? 15
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Paste your Claude API key here", text: $claudeKey)
                        .onSubmit { saveClaudeKey() }
                    Link("Get a key at console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .font(.caption)
                } header: {
                    Label("Claude API Key", systemImage: "sparkles")
                } footer: {
                    Text("Used for automatic close-call comparisons and on-demand AI review. Stored securely in your Keychain.")
                        .font(.caption)
                }

                Section {
                    SecureField("Paste your OpenAI API key here", text: $openAIKey)
                        .onSubmit { saveOpenAIKey() }
                    Link("Get a key at platform.openai.com", destination: URL(string: "https://platform.openai.com/api-keys")!)
                        .font(.caption)
                } header: {
                    Label("ChatGPT (GPT-4o) API Key", systemImage: "bubble.left.and.bubble.right.fill")
                } footer: {
                    Text("Used for on-demand GPT-4o photo comparison. Stored securely in your Keychain.")
                        .font(.caption)
                }

                Section {
                    SecureField("Paste your Groq API key here", text: $groqKey)
                        .onSubmit { saveGroqKey() }
                    Link("Get a key at console.groq.com", destination: URL(string: "https://console.groq.com/keys")!)
                        .font(.caption)
                    TextField("Model", text: $groqModel)
                } header: {
                    Label("Groq (Paid AI)", systemImage: "bolt.fill")
                } footer: {
                    Text("Used for on-demand AI review via Groq's hosted open-source models. The developer's key is used — no cost to you.")
                        .font(.caption)
                }

                Section {
                    Toggle("Paid features enabled", isOn: $isPaidUser)
                } header: {
                    Label("Account", systemImage: "person.circle")
                } footer: {
                    Text("Enables AI review features. In production this will be set by your subscription status.")
                        .font(.caption)
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Time window")
                            Spacer()
                            Text("\(Int(timeWindow)) seconds")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $timeWindow, in: 5...120, step: 5)
                        Text("Photos taken within this many seconds of each other are considered candidates for grouping. Increase it if burst shots are being missed; decrease it if unrelated photos are ending up in the same group.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Hash similarity threshold")
                            Spacer()
                            Text("\(Int(hashThreshold)) bits")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $hashThreshold, in: 5...25, step: 1)
                        Text("After time-grouping, each photo's visual fingerprint is compared to the others. This controls how different two fingerprints can be before the photos are considered visually distinct. Lower = stricter (fewer groups); higher = looser (more groups, may include less-similar shots).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Close-call threshold (AI)")
                            Spacer()
                            Text("\(Int(closeCallThreshold))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $closeCallThreshold, in: 5...40, step: 5)
                        Text("When the top two quality scores are within this percentage of each other, the winner is too close to call automatically and Claude is asked to decide. Raise it to send more groups to AI review; lower it to rely more on the on-device scorer.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Label("Grouping & Scoring", systemImage: "slider.horizontal.3")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 480)
    }

    private func saveClaudeKey() {
        if claudeKey.isEmpty { KeychainHelper.delete(key: "claude_api_key") }
        else { KeychainHelper.save(key: "claude_api_key", value: claudeKey) }
    }

    private func saveOpenAIKey() {
        if openAIKey.isEmpty { KeychainHelper.delete(key: "openai_api_key") }
        else { KeychainHelper.save(key: "openai_api_key", value: openAIKey) }
    }

    private func saveGroqKey() {
        if groqKey.isEmpty { KeychainHelper.delete(key: "groq_api_key") }
        else { KeychainHelper.save(key: "groq_api_key", value: groqKey) }
    }

    private func save() {
        if claudeKey.isEmpty {
            KeychainHelper.delete(key: "claude_api_key")
        } else {
            KeychainHelper.save(key: "claude_api_key", value: claudeKey)
        }
        if openAIKey.isEmpty {
            KeychainHelper.delete(key: "openai_api_key")
        } else {
            KeychainHelper.save(key: "openai_api_key", value: openAIKey)
        }
        if groqKey.isEmpty {
            KeychainHelper.delete(key: "groq_api_key")
        } else {
            KeychainHelper.save(key: "groq_api_key", value: groqKey)
        }
        UserDefaults.standard.set(groqModel, forKey: "groqModel")
        UserDefaults.standard.set(isPaidUser, forKey: "isPaidUser")
        UserDefaults.standard.set(timeWindow, forKey: "timeWindow")
        UserDefaults.standard.set(Int(hashThreshold), forKey: "pHashThreshold")
        UserDefaults.standard.set(closeCallThreshold, forKey: "closeCallThreshold")
        dismiss()
    }
}
