import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct SplashView: View {
    @ObservedObject var viewModel: ReviewViewModel
    @State private var showSettings = false
#if os(macOS)
    @State private var showFolderPicker = false
#endif
    @State private var showAlbumPicker = false

    @State private var showPhotoPicker = false
    @State private var photoAccessDenied = false
    @State private var photoAuthStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 24)

                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 90))
                    .foregroundStyle(.blue)

                VStack(spacing: 8) {
                    Text("DeDuper")
                        .font(.largeTitle.bold())
                    Text("Find and remove duplicate shots from your photo library.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }

                // Limited Photos Access banner
                if photoAuthStatus == .limited {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Limited Photos Access")
                                .font(.subheadline.bold())
                            Text("Only your selected photos will be scanned.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(.orange.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: 400)
                }

                VStack(spacing: 12) {
                    Button {
                        viewModel.startScan()
                    } label: {
                        Label("Scan Photos Library", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: 240)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help("Scan your entire Apple Photos library")

                    Button {
                        showAlbumPicker = true
                    } label: {
                        Label("Choose Album…", systemImage: "rectangle.stack")
                            .frame(maxWidth: 240)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Pick a specific album from your Photos library")

                    Button {
                        // Request authorization before presenting the library-backed
                        // picker so PHPickerConfiguration(photoLibrary:) can resolve
                        // asset identifiers correctly (works for both Limited and
                        // All Photos access).
                        Task {
                            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                            photoAuthStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                            if status == .authorized || status == .limited {
                                showPhotoPicker = true
                            } else {
                                photoAccessDenied = true
                            }
                        }
                    } label: {
                        Label("Select Photos…", systemImage: "photo.badge.checkmark")
                            .frame(maxWidth: 240)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Hand-pick individual photos to scan for duplicates")

#if os(macOS)
                    Button {
                        showFolderPicker = true
                    } label: {
                        Label("Choose Folder…", systemImage: "folder")
                            .frame(maxWidth: 240)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Pick a specific folder of photos to scan")
#endif
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
        .onAppear {
            photoAuthStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showAlbumPicker) {
            AlbumPickerView { album in
                viewModel.startAlbumScan(album: album)
            }
        }
#if os(macOS)
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
#endif
        // LibraryPhotoPicker uses NSWindow.beginSheet() — a true window-modal
        // sheet — so clicks inside the picker's sidebar cannot reach SwiftUI
        // buttons on the parent window.  (SwiftUI's .sheet() leaves the parent
        // window interactive, which caused sidebar clicks to bleed through and
        // open the album picker simultaneously.)
        .background(
            LibraryPhotoPicker(
                isPresented: $showPhotoPicker,
                filter: AppDefaults.scanVideosToo
                    ? PHPickerFilter.any(of: [.images, .videos])
                    : PHPickerFilter.images,
                onFinish: { results in
                    guard !results.isEmpty else { return }
                    let identifiers = results.compactMap { $0.assetIdentifier }.filter { !$0.isEmpty }
                    viewModel.startPickedPhotosScan(identifiers: identifiers)
                }
            )
            .frame(width: 0, height: 0)
        )
        .alert("Photos Access Required", isPresented: $photoAccessDenied) {
            Button("Open Settings") {
#if os(macOS)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                    NSWorkspace.shared.open(url)
                }
#else
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
#endif
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("DeDuper needs Photos library access to let you hand-pick photos. Open Settings → Privacy → Photos and choose \"All Photos\" or \"Limited Access\".")
        }
    }
}
