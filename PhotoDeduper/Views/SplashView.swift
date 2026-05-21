import SwiftUI
import UniformTypeIdentifiers

struct SplashView: View {
    @ObservedObject var viewModel: ReviewViewModel
    @State private var showSettings = false
    @State private var showFolderPicker = false
    @State private var showAlbumPicker = false

    // API key inline entry
    @State private var claudeKeyDraft: String = ""
    @State private var openAIKeyDraft: String = ""
    @State private var hasClaudeKey = false
    @State private var hasOpenAIKey = false
    @State private var hasGroqKey = false
    @State private var isPaidUser = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 24)

                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 90))
                    .foregroundStyle(.blue)

                VStack(spacing: 8) {
                    Text("Photo Deduper")
                        .font(.largeTitle.bold())
                    Text("Find and remove duplicate shots from your photo library.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }

                if isPaidUser {
                    apiKeySection
                }

                VStack(spacing: 12) {
                    Button {
                        viewModel.startScan()
                    } label: {
                        Label("Scan Photos Library", systemImage: "photo.on.rectangle")
                            .frame(width: 240)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help("Scan your entire Apple Photos library")

                    Button {
                        showAlbumPicker = true
                    } label: {
                        Label("Choose Album…", systemImage: "rectangle.stack")
                            .frame(width: 240)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Pick a specific album from your Photos library")

                    Button {
                        showFolderPicker = true
                    } label: {
                        Label("Choose Folder…", systemImage: "folder")
                            .frame(width: 240)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Pick a specific folder of photos to scan")
                }

                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: {
                    Image(systemName: "gear")
                }
                .help("Settings")
            }
        }
        .onAppear { refreshKeyStatus() }
        .onChange(of: showSettings) { _, isShowing in
            if !isShowing { refreshKeyStatus() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showAlbumPicker) {
            AlbumPickerView { album in
                viewModel.startAlbumScan(album: album)
            }
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                viewModel.startFolderScan(url: url)
            case .failure:
                break
            }
        }
    }

    // MARK: - API Key Section

    @ViewBuilder
    private var apiKeySection: some View {
        if !hasClaudeKey && !hasOpenAIKey && !hasGroqKey {
            // Banner: no keys configured
            VStack(alignment: .leading, spacing: 12) {
                Label("No AI keys configured", systemImage: "key.slash")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)

                Text("Add an Anthropic or OpenAI key to enable automatic close-call comparison.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    keyField(label: "Claude", placeholder: "sk-ant-…", provider: .claude,
                             draft: $claudeKeyDraft)
                    keyField(label: "ChatGPT", placeholder: "sk-…", provider: .openai,
                             draft: $openAIKeyDraft)
                }

                HStack {
                    Text("Stored securely · accessible only to this app")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Save") {
                        if !claudeKeyDraft.isEmpty { commitKey(for: .claude) }
                        if !openAIKeyDraft.isEmpty { commitKey(for: .openai) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(claudeKeyDraft.isEmpty && openAIKeyDraft.isEmpty)
                }
            }
            .padding(16)
            .background(.orange.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.orange.opacity(0.2), lineWidth: 1))
            .frame(maxWidth: 400)
        } else {
            // Status row: at least one key present
            HStack(spacing: 16) {
                keyStatusPill(provider: .claude, isActive: hasClaudeKey)
                keyStatusPill(provider: .openai, isActive: hasOpenAIKey)
                keyStatusPill(provider: .groq, isActive: hasGroqKey)
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Edit API keys in Settings")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.background.shadow(.drop(color: .black.opacity(0.05), radius: 4, y: 1)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: 400)
        }
    }

    private func keyField(label: String, placeholder: String, provider: AIProvider,
                          draft: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: provider.systemImage)
                .foregroundStyle(provider.accentColor)
                .frame(width: 18)
            Text(label)
                .font(.subheadline)
                .frame(width: 54, alignment: .leading)
            SecureField(placeholder, text: draft)
                .onSubmit { commitKey(for: provider) }
                .textFieldStyle(.roundedBorder)
        }
    }

    private func keyStatusPill(provider: AIProvider, isActive: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: provider.systemImage)
                .foregroundStyle(isActive ? provider.accentColor : .secondary)
                .font(.caption)
            Text(provider.displayName)
                .font(.caption.bold())
            Text(isActive ? "Active" : "—")
                .font(.caption)
                .foregroundStyle(isActive ? .green : .secondary)
        }
    }

    // MARK: - Keychain helpers

    private func commitKey(for provider: AIProvider) {
        let draft    = provider == .claude ? claudeKeyDraft : openAIKeyDraft
        let kwKey    = provider == .claude ? "claude_api_key" : "openai_api_key"
        if draft.isEmpty {
            KeychainHelper.delete(key: kwKey)
        } else {
            KeychainHelper.save(key: kwKey, value: draft)
        }
        // Clear draft immediately — never keep plaintext in @State longer than needed
        if provider == .claude { claudeKeyDraft = "" } else { openAIKeyDraft = "" }
        refreshKeyStatus()
    }

    private func refreshKeyStatus() {
        hasClaudeKey  = !(KeychainHelper.retrieve(key: "claude_api_key")  ?? "").isEmpty
        hasOpenAIKey  = !(KeychainHelper.retrieve(key: "openai_api_key")  ?? "").isEmpty
        hasGroqKey    = !(KeychainHelper.retrieve(key: "groq_api_key")    ?? "").isEmpty
        isPaidUser    = UserDefaults.standard.bool(forKey: "isPaidUser")
    }
}
