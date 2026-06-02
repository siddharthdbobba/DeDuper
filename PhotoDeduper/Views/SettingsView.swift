import SwiftUI
import Photos
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var sensitivity: Sensitivity = Sensitivity.current()
    @State private var timeWindow: Double = AppDefaults.timeWindow
    @State private var hashThreshold: Double = Double(AppDefaults.pHashThreshold)
    @State private var closeCallThreshold: Double = AppDefaults.closeCallThreshold

    @State private var scanVideosToo: Bool = AppDefaults.scanVideosToo
    @State private var holdForReview: Bool = AppDefaults.holdForReview

    @State private var showProtectedPicker = false
    @State private var protectedAlbumIDs: [String] = AppDefaults.protectedAlbumIDs
    @State private var protectedAlbums: [PhotoAlbum] = []
    @State private var auditExportURL: URL?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
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
            .task { await loadProtectedAlbumTitles() }
            .onChange(of: protectedAlbumIDs) { _, _ in
                Task { await loadProtectedAlbumTitles() }
            }
        }
#if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
#endif
    }

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
                Slider(value: $closeCallThreshold, in: 5...40, step: 1)
                    .onChange(of: closeCallThreshold) { _, _ in sensitivity = sensitivityFromSliders() }
                Text("When the top two scores are within this percent, the on-device resolver takes over.")
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
        Sensitivity.matching(timeWindow: timeWindow, hash: Int(hashThreshold), closeCall: closeCallThreshold)
    }

    private func save() {
        AppDefaults.timeWindow = timeWindow
        AppDefaults.pHashThreshold = Int(hashThreshold)
        AppDefaults.closeCallThreshold = closeCallThreshold
        AppDefaults.scanVideosToo = scanVideosToo
        AppDefaults.holdForReview = holdForReview
        AppDefaults.protectedAlbumIDs = protectedAlbumIDs
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

    /// The fixed threshold triple for each preset, or `nil` for `.custom`.
    /// Single source of truth for both applying a preset and reverse-matching one.
    var thresholds: (timeWindow: Double, hash: Int, closeCall: Double)? {
        switch self {
        case .conservative: (15, 8, 8)
        case .balanced:     (30, 15, 15)
        case .aggressive:   (60, 20, 25)
        case .custom:       nil
        }
    }

    /// The preset whose thresholds exactly match the given values, or `.custom`.
    static func matching(timeWindow: Double, hash: Int, closeCall: Double) -> Sensitivity {
        for preset in allCases {
            if let t = preset.thresholds,
               t.timeWindow == timeWindow, t.hash == hash, t.closeCall == closeCall {
                return preset
            }
        }
        return .custom
    }

    static func current() -> Sensitivity {
        matching(timeWindow: AppDefaults.timeWindow, hash: AppDefaults.pHashThreshold, closeCall: AppDefaults.closeCallThreshold)
    }

    func apply(to timeWindow: inout Double, hashThreshold: inout Double, closeCallThreshold: inout Double) {
        guard let t = thresholds else { return }
        timeWindow = t.timeWindow
        hashThreshold = Double(t.hash)
        closeCallThreshold = Double(t.closeCall)
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
