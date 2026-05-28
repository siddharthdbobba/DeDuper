import SwiftUI
import Photos

struct AlbumPickerView: View {
    let onSelect: (PhotoAlbum) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var smartAlbums: [PhotoAlbum] = []
    @State private var userAlbums:  [PhotoAlbum] = []
    @State private var isLoading = true
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading albums…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if smartAlbums.isEmpty && userAlbums.isEmpty {
                    ContentUnavailableView(
                        "No Albums Found",
                        systemImage: "rectangle.stack",
                        description: Text("Grant Photos access to see your albums.")
                    )
                } else {
                    albumList
                }
            }
            .navigationTitle("Choose Album")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 420, minHeight: 500)
#endif
        .task { await loadAlbums() }
    }

    // MARK: - List

    private var albumList: some View {
        List {
            if !filteredSmart.isEmpty {
                Section("Smart Albums") {
                    ForEach(filteredSmart) { album in
                        albumRow(album)
                    }
                }
            }
            if !filteredUser.isEmpty {
                Section("My Albums") {
                    ForEach(filteredUser) { album in
                        albumRow(album)
                    }
                }
            }
        }
        .listStyle(.inset)
        .searchable(text: $searchText, prompt: "Search albums")
    }

    private func albumRow(_ album: PhotoAlbum) -> some View {
        Button {
            onSelect(album)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                AlbumThumbnailView(collection: album.collection)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Text("\(album.count) photo\(album.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Filtering

    private var filteredSmart: [PhotoAlbum] {
        searchText.isEmpty ? smartAlbums : smartAlbums.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredUser: [PhotoAlbum] {
        searchText.isEmpty ? userAlbums : userAlbums.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Data loading

    private func loadAlbums() async {
        let lib = PhotoLibraryManager()
        guard await lib.requestAuthorization() else {
            isLoading = false
            return
        }
        // fetchAlbums counts assets per album — run off the main thread to avoid blocking the UI.
        let all = await Task.detached(priority: .userInitiated) { lib.fetchAlbums() }.value
        smartAlbums = all.filter { $0.collectionType == .smartAlbum }
        userAlbums  = all.filter { $0.collectionType == .album }
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        isLoading = false
    }
}

// MARK: - Album thumbnail (most-recent photo in the collection)

struct AlbumThumbnailView: View {
    let collection: PHAssetCollection
    @State private var image: PlatformImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image).resizable().scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .onAppear(perform: load)
        .onDisappear {
            if let id = requestID {
                PHImageManager.default().cancelImageRequest(id)
                requestID = nil
            }
        }
    }

    private func load() {
        let fetchOptions = PHFetchOptions()
        fetchOptions.fetchLimit = 1
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        guard let asset = PHAsset.fetchAssets(in: collection, options: fetchOptions).firstObject else { return }

        let imgOptions = PHImageRequestOptions()
        imgOptions.deliveryMode = .fastFormat
        imgOptions.resizeMode = .fast
        imgOptions.isNetworkAccessAllowed = false

        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 104, height: 104),
            contentMode: .aspectFill,
            options: imgOptions
        ) { image, _ in
            if let image {
                Task { @MainActor in self.image = image }
            }
        }
    }
}
