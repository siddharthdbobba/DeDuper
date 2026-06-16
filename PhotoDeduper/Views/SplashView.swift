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

    /// Drives the one-time "Find duplicates privately" preamble shown before the
    /// very first macOS Photos permission dialog. A cautious user faced with a
    /// bare OS prompt (no context about why a photo app wants their library) may
    /// reflexively deny — and a denial is sticky (only recoverable via System
    /// Settings). The preamble gives them the privacy reassurance ("scans on
    /// this Mac, nothing uploaded") *before* the irreversible OS choice.
    @State private var showPermissionPreamble = false
    /// The library-backed scan to run once the user taps "Continue" on the
    /// preamble. Captured because the preamble sits between the button tap and
    /// the actual scan call that triggers the OS prompt — tapping "Continue"
    /// must resume the exact action ("Scan Photos Library" vs "Choose Album")
    /// the user originally chose. A single stored closure + one `.alert` keeps
    /// this reusable across both library-backed entry points.
    @State private var pendingLibraryAction: (() -> Void)?

    /// Routes a library-backed scan through the permission preamble exactly once.
    ///
    /// Gating purely on `.notDetermined` is deliberate and needs no persisted
    /// flag: the preamble only precedes the *first* OS prompt, and once the user
    /// answers that prompt the status moves to `.authorized`/`.limited`/`.denied`
    /// — never back to `.notDetermined` — so this naturally fires at most once
    /// per install. In every already-decided state we run `action` directly,
    /// preserving today's behavior (authorized scans straight through; a denied
    /// status lets `action`'s own auth check surface the recovery path).
    private func runLibraryAction(_ action: @escaping () -> Void) {
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            pendingLibraryAction = action
            showPermissionPreamble = true
        } else {
            action()
        }
    }

    /// Opens the macOS Photos privacy pane. Shared by the persistent
    /// denied/restricted banner and the "Select Photos" denied alert so both
    /// recovery affordances point at the exact same Settings destination —
    /// previously only the alert knew how to do this.
    private func openPhotosPrivacySettings() {
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

                // Persistent denied / restricted banner. Unlike the one-shot
                // "Photos Access Required" alert (which only fires off the
                // "Select Photos" path), this stays visible the whole time
                // access is off, so a user who lands on the splash with a prior
                // denial sees the recovery route without first tapping a
                // library-backed button. `.restricted` (parental controls / MDM)
                // can't be self-fixed, but the same Settings deep-link is still
                // the right place to point. Non-blocking by design: "Choose
                // Folder" needs no Photos access and remains usable below.
                if photoAuthStatus == .denied || photoAuthStatus == .restricted {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Photo access is off — the library scans need permission.")
                                .font(.subheadline.bold())
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                        Button("Open Settings") { openPhotosPrivacySettings() }
                            .controlSize(.small)
                    }
                    .padding(12)
                    .background(.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: 400)
                }

                // Limited Photos Access banner
                if photoAuthStatus == .limited {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Limited Photos Access")
                                .font(.subheadline.bold())
                            // Expanded from "Only your selected photos will be
                            // scanned." to an actionable instruction: users with
                            // Limited access often don't realize it's *why* their
                            // scan came back nearly empty, nor how to widen it.
                            // Spell out the exact System Settings path and the
                            // "All Photos" choice that fixes it.
                            Text("Only the photos you've shared are scanned. To scan everything, open System Settings → Privacy & Security → Photos and choose \"All Photos\".")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(.orange.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: 400)
                }

                // Each button now carries a one-line secondary caption (small,
                // .secondary) under its title so the four near-identical entry
                // points are distinguishable at a glance — previously the only
                // hint at the difference lived in a hover `.help` tooltip, which
                // is invisible on first run and unreachable by touch. The caption
                // lives *inside* the button's label VStack so it shares the
                // button's tap target and stays vertically centered with it; the
                // shared 240pt frame keeps every button the same width and the
                // captions left-aligned to a common column.
                VStack(spacing: 12) {
                    Button {
                        // Route through the preamble: "Scan Photos Library" is
                        // the most common first tap, so it's the most important
                        // one to precede with privacy context before the OS
                        // prompt. Skips straight to startScan() once access is
                        // already decided (see runLibraryAction).
                        runLibraryAction { viewModel.startScan() }
                    } label: {
                        entryButtonLabel(
                            title: "Scan Photos Library",
                            caption: "Find duplicates across your whole library",
                            systemImage: "photo.on.rectangle"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help("Scan your entire Apple Photos library")

                    Button {
                        // Choosing an album also reads the Photos library (the
                        // album picker fetches collections), so it triggers the
                        // same OS prompt and gets the same preamble. Showing the
                        // picker *is* the action resumed after "Continue".
                        runLibraryAction { showAlbumPicker = true }
                    } label: {
                        entryButtonLabel(
                            title: "Choose Album…",
                            caption: "Scan just one album",
                            systemImage: "rectangle.stack"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Pick a specific album from your Photos library")

                    Button {
                        // Request authorization before presenting the library-backed
                        // picker so PHPickerConfiguration(photoLibrary:) can resolve
                        // asset identifiers correctly (works for both Limited and
                        // All Photos access).
                        //
                        // No preamble here on purpose: this path already calls
                        // requestAuthorization itself and, on denial, raises its
                        // own actionable "Photos Access Required" alert — adding
                        // the preamble would stack two dialogs before the picker.
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
                        entryButtonLabel(
                            title: "Select Photos…",
                            caption: "Hand-pick specific photos to compare",
                            systemImage: "photo.badge.checkmark"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Hand-pick individual photos to scan for duplicates")

#if os(macOS)
                    Button {
                        showFolderPicker = true
                    } label: {
                        entryButtonLabel(
                            title: "Choose Folder…",
                            caption: "Scan image files in a folder on your Mac",
                            systemImage: "folder"
                        )
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
            Button("Open Settings") { openPhotosPrivacySettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("DeDuper needs Photos library access to let you hand-pick photos. Open Settings → Privacy → Photos and choose \"All Photos\" or \"Limited Access\".")
        }
        // One-time pre-prompt for the library-backed scans. "Continue" resumes
        // the exact action the user tapped (captured in pendingLibraryAction),
        // which is what actually fires the macOS permission dialog; "Not now"
        // backs out without prompting. The closure is cleared on either choice
        // so a stale action can't be replayed by a later, unrelated prompt.
        .alert("Find duplicates privately", isPresented: $showPermissionPreamble) {
            Button("Continue") {
                let action = pendingLibraryAction
                pendingLibraryAction = nil
                action?()
            }
            Button("Not now", role: .cancel) {
                pendingLibraryAction = nil
            }
        } message: {
            Text("DeDuper scans your photos right on this Mac to find duplicates — nothing is uploaded, no account needed. Next, macOS will ask permission to access your photos.")
        }
    }

    /// Title + secondary caption stack for an entry button, with the leading
    /// icon preserved. Pulled into a helper so all four buttons share identical
    /// spacing/typography (and so each call site reads as a tidy 3-line
    /// description). The fixed 240pt width matches the original `.frame` and
    /// keeps every button the same size regardless of caption length.
    private func entryButtonLabel(title: String, caption: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 240, alignment: .leading)
    }
}
