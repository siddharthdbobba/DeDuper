import SwiftUI
import Photos
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var autoReviewEnabled: Bool = UserDefaults.standard.bool(forKey: "autoReviewEnabled")
    @ObservedObject private var entitlements = EntitlementStore.shared
    @State private var showPaywall = false

    @State private var sensitivity: Sensitivity = Sensitivity.current()
    @State private var timeWindow: Double = UserDefaults.standard.object(forKey: "timeWindow") as? Double ?? 30
    @State private var hashThreshold: Double = Double(UserDefaults.standard.object(forKey: "pHashThreshold") as? Int ?? 20)
    @State private var closeCallThreshold: Double = UserDefaults.standard.object(forKey: "closeCallThreshold") as? Double ?? 15

    @State private var scanVideosToo: Bool = UserDefaults.standard.bool(forKey: "scanVideosToo")
    @State private var crossFormatEnabled: Bool = UserDefaults.standard.object(forKey: "crossFormatEnabled") as? Bool ?? true
    @State private var holdForReview: Bool = UserDefaults.standard.bool(forKey: "holdForReview")

    @State private var showProtectedPicker = false
    @State private var protectedAlbumIDs: [String] = (UserDefaults.standard.array(forKey: "protectedAlbumIDs") as? [String]) ?? []
    @State private var protectedAlbums: [PhotoAlbum] = []
    @State private var auditExportURL: URL?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                bundledAISection
                #if DIRECT_DISTRIBUTION
                licenseSection
                #endif
                groupingSection
                behaviorSection
                protectedAlbumsSection
                auditSection
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
            .sheet(isPresented: $showProtectedPicker) {
                ProtectedAlbumsPicker(selected: $protectedAlbumIDs)
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
            .task { await loadProtectedAlbumTitles() }
            .onChange(of: protectedAlbumIDs) { _, _ in
                Task { await loadProtectedAlbumTitles() }
            }
        }
#if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
#endif
    }

    // MARK: - Bundled AI section

    private var bundledAISection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.blue)
                    .imageScale(.large)
                VStack(alignment: .leading, spacing: 2) {
                    Text("GPT-4.1 mini")
                        .fontWeight(.medium)
                    Text("No key required — included with the app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if entitlements.hasPremium {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Upgrade") { showPaywall = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.blue)
                }
            }
            .padding(.vertical, 2)

            if entitlements.hasPremium {
                Toggle("Auto-review close calls", isOn: $autoReviewEnabled)
            } else {
                HStack {
                    Text("Auto-review close calls")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .contentShape(Rectangle())
                .onTapGesture { showPaywall = true }
            }
        } header: {
            Label("Bundled AI", systemImage: "wand.and.stars")
        } footer: {
            Text(entitlements.hasPremium
                 ? "Automatically picks the best photo in close-call groups during scanning. No sign-up or API key needed."
                 : "Upgrade to DeDuper Premium to enable AI-powered close-call resolution during scanning.")
                .font(.caption)
        }
    }

    // MARK: - License (Direct Distribution only)

    #if DIRECT_DISTRIBUTION
    @State private var showLicenseEntry = false

    private var licenseSection: some View {
        Section {
            if entitlements.hasPremium {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DeDuper Premium")
                            .fontWeight(.medium)
                        if let masked = LemonSqueezyManager.shared.maskedKey {
                            Text(masked)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fontDesign(.monospaced)
                        }
                    }
                }
                .padding(.vertical, 2)

                Button(role: .destructive) {
                    Task { await entitlements.deactivateLicense() }
                } label: {
                    Label("Deactivate This Mac", systemImage: "xmark.circle")
                }
                .disabled(entitlements.isLoading)
            } else {
                Button {
                    showLicenseEntry = true
                } label: {
                    Label("Enter License Key…", systemImage: "key.fill")
                }
            }
        } header: {
            Label("License", systemImage: "checkmark.seal")
        } footer: {
            if entitlements.hasPremium {
                Text("Deactivating frees up one activation slot so you can use your key on another Mac.")
                    .font(.caption)
            } else {
                Text("Already purchased? Enter your license key to unlock premium features.")
                    .font(.caption)
            }
        }
        .sheet(isPresented: $showLicenseEntry) {
            LicenseKeyEntryView()
        }
    }
    #endif

    // MARK: - Grouping & Scoring

    private var groupingSection: some View {
        Section {
            Picker("Sensitivity", selection: $sensitivity) {
                ForEach(Sensitivity.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: sensitivity) { _, new in
                new.apply(to: &timeWindow, hashThreshold: &hashThreshold, closeCallThreshold: &closeCallThreshold)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Time window")
                    Spacer()
                    Text("\(Int(timeWindow)) seconds")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $timeWindow, in: 5...120, step: 5)
                    .onChange(of: timeWindow) { _, _ in sensitivity = sensitivityFromSliders() }
                Text("Photos taken within this many seconds of each other are candidates for grouping.")
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
                Slider(value: $hashThreshold, in: 5...30, step: 1)
                    .onChange(of: hashThreshold) { _, _ in sensitivity = sensitivityFromSliders() }
                Text("Lower = stricter; higher = looser.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Close-call threshold")
                    Spacer()
                    Text("\(Int(closeCallThreshold))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $closeCallThreshold, in: 5...40, step: 5)
                    .onChange(of: closeCallThreshold) { _, _ in sensitivity = sensitivityFromSliders() }
                Text("When the top two scores are within this percent, the on-device resolver and AI take over.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label("Grouping & Scoring", systemImage: "slider.horizontal.3")
        }
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        Section {
            Toggle(isOn: $scanVideosToo) {
                Label("Include videos", systemImage: "play.rectangle")
            }
            Toggle(isOn: $crossFormatEnabled) {
                Label("Find HEIC ↔ JPG duplicates", systemImage: "arrow.left.arrow.right")
            }
            Toggle(isOn: $holdForReview) {
                Label("Hold for review (don't delete immediately)", systemImage: "tray.full")
            }
        } header: {
            Label("Behavior", systemImage: "switch.2")
        } footer: {
            Text("Hold-for-review adds flagged photos to a \"PhotoDeduper Review\" album in Photos instead of deleting them, so you can audit them before manually trashing.")
                .font(.caption)
        }
    }

    // MARK: - Protected Albums

    private var protectedAlbumsSection: some View {
        Section {
            if protectedAlbums.isEmpty {
                Text("No protected albums. Favorites are always protected automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(protectedAlbums, id: \.id) { album in
                    HStack(spacing: 10) {
                        Image(systemName: "lock.fill").foregroundStyle(.blue)
                        Text(album.title)
                        Spacer()
                        Text("\(album.count)").foregroundStyle(.secondary).monospacedDigit()
                        Button {
                            protectedAlbumIDs.removeAll { $0 == album.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button {
                showProtectedPicker = true
            } label: {
                Label("Add protected album…", systemImage: "plus")
            }
        } header: {
            Label("Protected Albums", systemImage: "lock.shield")
        } footer: {
            Text("Photos in these albums (and any photo marked as a favorite) are never marked for deletion. Useful for \"Best of\" or family-portrait albums.")
                .font(.caption)
        }
    }

    // MARK: - Audit Log

    private var auditSection: some View {
        Section {
            if let url = auditExportURL {
                ShareLink(item: url, subject: Text("PhotoDeduper Audit Log")) {
                    Label("Share audit log (CSV)", systemImage: "square.and.arrow.up")
                }
            } else {
                Button {
                    prepareAuditExport()
                } label: {
                    Label("Export audit log (CSV)…", systemImage: "square.and.arrow.up")
                }
            }
            Text("Total deletions: \(AuditLogger.shared.totalDeletions()) · Estimated bytes freed: \(ByteCountFormatter.string(fromByteCount: AuditLogger.shared.totalEstimatedBytes(), countStyle: .file))")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Label("Audit Log", systemImage: "doc.text.magnifyingglass")
        }
    }

    private func prepareAuditExport() {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("photodeduper-audit.csv")
        try? AuditLogger.shared.exportCSV(to: tmpURL)
        auditExportURL = tmpURL
    }

    // MARK: - Save / load

    private func loadProtectedAlbumTitles() async {
        guard !protectedAlbumIDs.isEmpty else { protectedAlbums = []; return }
        let lib = PhotoLibraryManager()
        let all = await Task.detached(priority: .userInitiated) { lib.fetchAlbums() }.value
        protectedAlbums = all.filter { protectedAlbumIDs.contains($0.id) }
    }

    /// Derive the sensitivity preset from the current slider values.
    /// Returns the matching preset if sliders exactly match one, otherwise `.custom`.
    /// This prevents a feedback loop where applying a preset updates the sliders,
    /// which in turn would fire onChange and revert sensitivity back to `.custom`.
    private func sensitivityFromSliders() -> Sensitivity {
        if timeWindow == 15, Int(hashThreshold) == 8,  closeCallThreshold == 8  { return .conservative }
        if timeWindow == 30, Int(hashThreshold) == 15, closeCallThreshold == 15 { return .balanced }
        if timeWindow == 60, Int(hashThreshold) == 20, closeCallThreshold == 25 { return .aggressive }
        return .custom
    }

    private func save() {
        UserDefaults.standard.set(autoReviewEnabled, forKey: "autoReviewEnabled")
        UserDefaults.standard.set(timeWindow, forKey: "timeWindow")
        UserDefaults.standard.set(Int(hashThreshold), forKey: "pHashThreshold")
        UserDefaults.standard.set(closeCallThreshold, forKey: "closeCallThreshold")
        UserDefaults.standard.set(scanVideosToo, forKey: "scanVideosToo")
        UserDefaults.standard.set(crossFormatEnabled, forKey: "crossFormatEnabled")
        UserDefaults.standard.set(holdForReview, forKey: "holdForReview")
        UserDefaults.standard.set(protectedAlbumIDs, forKey: "protectedAlbumIDs")
        dismiss()
    }
}

// MARK: - Sensitivity preset

enum Sensitivity: String, CaseIterable, Identifiable, Hashable {
    case conservative, balanced, aggressive, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .conservative: "Conservative"
        case .balanced:     "Balanced"
        case .aggressive:   "Aggressive"
        case .custom:       "Custom"
        }
    }

    static func current() -> Sensitivity {
        let tw  = UserDefaults.standard.object(forKey: "timeWindow") as? Double ?? 30
        let ph  = UserDefaults.standard.object(forKey: "pHashThreshold") as? Int ?? 20
        let cc  = UserDefaults.standard.object(forKey: "closeCallThreshold") as? Double ?? 15
        if tw == 15, ph == 8,  cc == 8  { return .conservative }
        if tw == 30, ph == 15, cc == 15 { return .balanced }
        if tw == 60, ph == 20, cc == 25 { return .aggressive }
        return .custom
    }

    func apply(to timeWindow: inout Double, hashThreshold: inout Double, closeCallThreshold: inout Double) {
        switch self {
        case .conservative:
            timeWindow = 15;  hashThreshold = 8;  closeCallThreshold = 8
        case .balanced:
            timeWindow = 30;  hashThreshold = 15; closeCallThreshold = 15
        case .aggressive:
            timeWindow = 60;  hashThreshold = 20; closeCallThreshold = 25
        case .custom:
            break
        }
    }
}

// MARK: - Protected albums picker

struct ProtectedAlbumsPicker: View {
    @Binding var selected: [String]
    @State private var allAlbums: [PhotoAlbum] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading albums…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filtered, id: \.id) { album in
                            Button {
                                toggle(album.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selected.contains(album.id) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(selected.contains(album.id) ? .blue : .secondary)
                                    Text(album.title)
                                    Spacer()
                                    Text("\(album.count) photos")
                                        .foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search albums")
                }
            }
            .navigationTitle("Protect Albums")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 440, minHeight: 460)
#endif
        .task { await loadAlbums() }
    }

    private var filtered: [PhotoAlbum] {
        searchText.isEmpty ? allAlbums : allAlbums.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) {
            selected.removeAll { $0 == id }
        } else {
            selected.append(id)
        }
    }

    private func loadAlbums() async {
        let lib = PhotoLibraryManager()
        guard await lib.requestAuthorization() else {
            isLoading = false; return
        }
        let albums = await Task.detached(priority: .userInitiated) { lib.fetchAlbums() }.value
        allAlbums = albums.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        isLoading = false
    }
}
