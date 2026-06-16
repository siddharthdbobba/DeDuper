import SwiftUI
import Photos

struct ReviewView: View {
    @ObservedObject var viewModel: ReviewViewModel
    @FocusState private var isFocused: Bool
    /// Whether the Face-to-Face overlay fills the window edge-to-edge — its own
    /// in-app "full screen", distinct from the app window's native full-screen.
    @State private var faceToFaceMaximized = false
    /// Drives the ONE-TIME-EVER delete explainer alert. Shown the first time a
    /// user ever flushes while "Confirm before delete" is OFF — see deleteButton
    /// for the three-way branch and AppDefaults.hasSeenDeleteInfo for the latch.
    @State private var showDeleteInfo = false
    /// Drives the keyboard-shortcut legend popover (toolbar "?" button). The
    /// review screen has rich key navigation (j/k, arrows, 1–9, Return, ⌘Z,
    /// ⌘-click) that was previously undiscoverable — the only on-screen hint
    /// named just F and D — so this popover surfaces the full set on demand.
    @State private var showShortcuts = false
    /// Drives the in-review Settings sheet (toolbar gear). Settings used to be
    /// reachable only from the Splash screen, so tweaking thresholds mid-review
    /// meant abandoning the session via Home; this lets the user open Settings
    /// without losing their place. SettingsView is self-contained (reads/writes
    /// AppDefaults), so presenting it here Just Works.
    @State private var showSettings = false
    /// Snapshot of the scan-affecting AppDefaults taken the instant Settings
    /// opens, so we can tell on dismissal whether the user changed anything that
    /// the CURRENT results don't reflect (those values are read once at scan
    /// time). A real change flips `viewModel.pendingRescan`, surfacing the
    /// "Settings changed — they apply to a new scan" banner with a Rescan offer.
    /// Only these five settings affect grouping/scoring; behavior-only toggles
    /// (confirm-before-delete, hold-for-review) deliberately don't trigger it.
    @State private var settingsSnapshot: ScanSettingsSnapshot?

    var body: some View {
        ZStack(alignment: .bottom) {
            NavigationSplitView {
                sidebarContent
            } detail: {
                detail
            }
            .navigationSplitViewStyle(.balanced)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        viewModel.reset()
                    } label: {
                        Label("Home", systemImage: "house")
                    }
                    .help("Return to Home")
                    // The macOS toolbar collapses this Label to icon-only, so
                    // VoiceOver would otherwise announce just "house, button".
                    .accessibilityLabel("Home")
                }
                // Settings, in-review. Lives next to Home so the gear is where
                // users expect a "leave/configure" control, and so a mid-review
                // tweak no longer forces a trip back to Splash. Snapshotting the
                // scan-affecting defaults happens in the gear's action (before
                // the sheet opens), and the post-dismiss compare lives in the
                // sheet's onDismiss below — so the toolbar entry stays a plain
                // button and ReviewView's already-heavy body gains no closures.
                ToolbarItem(placement: .navigation) {
                    Button {
                        settingsSnapshot = ScanSettingsSnapshot.current()
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings")
                    // Icon-only: .help is a hover tooltip VoiceOver can't read, so
                    // pair it with an explicit label or it announces as "button".
                    .accessibilityLabel("Settings")
                }
                // "Set Aside All" — the bulk-stage shortcut for a user who
                // trusts the proposed keepers and doesn't want to walk every
                // group with `d`. Gated on `groups.count > 1`: with 0 or 1 live
                // group it earns nothing over the per-group action (and would
                // duplicate the detail view's "Set Aside" on a single group),
                // so it only appears once there's a real batch to collapse.
                // Non-destructive styling (plain bordered, NOT the red
                // borderedProminent the delete button uses): staging touches
                // nothing on disk, so signaling danger here would be dishonest —
                // the user can Restore from the sidebar footer. Placed before
                // the delete button so the flow reads left-to-right "set aside →
                // delete".
                if viewModel.groups.count > 1 {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            viewModel.stageAllGroups()
                        } label: {
                            Label("Set Aside All", systemImage: "tray.and.arrow.down.fill")
                        }
                        .help("Set every remaining group aside for deletion (you can Restore from the sidebar)")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    deleteButton
                }
                // Keyboard-shortcut legend. A toolbar button (NOT a key-press
                // handler) is deliberate: it lives outside ReviewView's focus
                // chain, so opening/closing it can't disturb the .focused /
                // .onKeyPress wiring below that the j/k/arrow/1–9 navigation
                // depends on. The popover content is a separate view struct
                // (ShortcutLegend) so this body/toolbar stays small enough to
                // sidestep the type-checker's expression-complexity ceiling.
                ToolbarItem(placement: .automatic) {
                    Button {
                        showShortcuts.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .help("Keyboard shortcuts")
                    // Icon-only: give VoiceOver the purpose the "?" glyph alone
                    // can't convey (.help is hover-only and unread by screen readers).
                    .accessibilityLabel("Keyboard shortcuts")
                    .popover(isPresented: $showShortcuts, arrowEdge: .bottom) {
                        ShortcutLegend()
                    }
                }
            }
            .sheet(isPresented: $viewModel.showConfirmDelete) {
                ConfirmDeleteSheet(viewModel: viewModel)
            }
            // ONE-TIME-EVER delete explainer. Latched by AppDefaults.hasSeenDeleteInfo,
            // set true the moment the user confirms — a brand-new user sees this once
            // and is frictionless forever after (the deliberate default). The flush
            // button (a ToolbarItem) only flips `showDeleteInfo`; the alert MUST live
            // here on the main body, NOT on the toolbar button — a `.alert` attached
            // to toolbar content is hoisted into AppKit and silently fails to present,
            // which let an unexplained first delete slip through with no warning.
            .alert("Delete is immediate", isPresented: $showDeleteInfo) {
                Button("Delete \(viewModel.totalToDelete) Photos", role: .destructive) {
                    AppDefaults.hasSeenDeleteInfo = true
                    Task { await viewModel.confirmDelete() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                // Recovery wording follows the deletion backend: folder scans move
                // files to the macOS Trash; Photos-library scans move assets to
                // Recently Deleted. Both stay recoverable for 30 days.
                Text(viewModel.isFolderScan
                     ? "Marked photos are removed right away — they go to the macOS Trash and stay recoverable for 30 days. You can turn on a confirmation each time in Settings."
                     : "Marked photos are removed right away — they go to Recently Deleted in Photos and stay recoverable for 30 days. You can turn on a confirmation each time in Settings.")
            }
            // In-review Settings. onDismiss fires on EVERY close path (Save,
            // Cancel, Esc, click-away), so the post-close compare runs once
            // here rather than being duplicated across each dismissal route.
            // SettingsView only persists on Save, so a Cancel leaves the
            // snapshot equal to current and `changedSinceSnapshot` stays false —
            // no spurious banner. We OR into pendingRescan (never clear it) so a
            // second visit that reverts the change doesn't retract a banner the
            // user might already be acting on.
            .sheet(isPresented: $showSettings, onDismiss: {
                if let snapshot = settingsSnapshot, snapshot.changedSinceSnapshot() {
                    viewModel.pendingRescan = true
                }
                settingsSnapshot = nil
            }) {
                SettingsView()
            }
            .navigationTitle("DeDuper")
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onAppear { isFocused = true }
            // Defensive Esc: if focus stayed on ReviewView while the
            // Face-to-Face overlay is up (FaceToFaceView's focus grab can race
            // view insertion), Esc must still close the overlay. Otherwise let
            // Esc keep its default behavior.
            // ORDERING IS LOAD-BEARING: this handler must stay before (inner to)
            // the catch-all onKeyPress below, which swallows keys while the
            // overlay is up — moved after it, this fallback would never fire.
            .onKeyPress(.escape) {
                guard viewModel.faceToFaceGroupID != nil else { return .ignored }
                closeFaceToFace()
                return .handled
            }
#if os(macOS)
            // Verified live: macOS routes Esc through the cancel command
            // (cancelOperation:) ahead of key-press dispatch, so the handler
            // above may never see it. onExitCommand is the reliable hook.
            .onExitCommand {
                if viewModel.faceToFaceGroupID != nil { closeFaceToFace() }
            }
#endif
            // Each handler below is guarded with `faceToFaceGroupID == nil`:
            // while the overlay is up these shortcuts must not act invisibly
            // behind it (`d` would stage the selected group!), so swallow the
            // key (`.handled` no-op) instead of acting on it.
            .onKeyPress(.return) {
                guard viewModel.faceToFaceGroupID == nil else { return .handled }
                viewModel.selectNextGroup(); return .handled
            }
            .onKeyPress(.downArrow) {
                guard viewModel.faceToFaceGroupID == nil else { return .handled }
                viewModel.selectNextGroup(); return .handled
            }
            .onKeyPress(.upArrow) {
                guard viewModel.faceToFaceGroupID == nil else { return .handled }
                viewModel.selectPreviousGroup(); return .handled
            }
            .onKeyPress("j") {
                guard viewModel.faceToFaceGroupID == nil else { return .handled }
                viewModel.selectNextGroup(); return .handled
            }
            .onKeyPress("k") {
                guard viewModel.faceToFaceGroupID == nil else { return .handled }
                viewModel.selectPreviousGroup(); return .handled
            }
            .onKeyPress("d") {
                guard viewModel.faceToFaceGroupID == nil else { return .handled }
                stageCurrent(); return .handled
            }
            .onKeyPress("f") {
                guard viewModel.faceToFaceGroupID == nil else { return .handled }
                if let id = viewModel.selectedGroupID,
                   let group = viewModel.groups.first(where: { $0.id == id }),
                   group.items.count >= 2 {
                    viewModel.faceToFaceGroupID = id
                }
                return .handled
            }
            .onKeyPress { press in
                // Swallow stray keys while the Face-to-Face overlay is up (see
                // the guard comment above) — Esc is handled separately.
                guard viewModel.faceToFaceGroupID == nil else { return .handled }
                // Number keys 1-9 select the corresponding photo in the current group.
                // Ignore if a modifier is held — Cmd+1 etc. belong to the system.
                guard press.modifiers.isEmpty else { return .ignored }
                guard let digit = Int(press.characters), digit >= 1, digit <= 9 else { return .ignored }
                guard let id = viewModel.selectedGroupID,
                      let group = viewModel.groups.first(where: { $0.id == id }) else { return .ignored }
                let target = digit - 1
                guard target < group.items.count else { return .ignored }
                viewModel.selectKeeper(groupID: id, itemIndex: target)
                return .handled
            }
            .background(
                // Hidden control to provide Cmd+Z = undo while focused.
                Button("") {
                    Task { await viewModel.attemptUndo() }
                }
                .keyboardShortcut("z", modifiers: .command)
                .hidden()
                .disabled(!viewModel.hasActiveUndo)
            )

            // Bottom overlay stack: the transient notice (partial-failure /
            // undo-shortfall copy) rides above the undo banner because a
            // partial delete legitimately shows both at once — successes are
            // undoable while the notice explains the failures.
            VStack(spacing: 10) {
                // Rescan prompt rides at the TOP of the stack: it's an
                // informational nudge, not an outcome of a delete, so it sits
                // above the notice/undo banners (which report what just
                // happened to the user's photos and deserve the lower, more
                // prominent slot nearest the action).
                if viewModel.pendingRescan {
                    rescanBanner
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let notice = viewModel.transientNotice {
                    noticeBanner(notice)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if viewModel.hasActiveUndo {
                    undoBanner
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 16)

            // Face-to-Face comparison — hosted at the window root (not as a sheet)
            // so it can toggle native full-screen and be dismissed by clicking the
            // dimmed backdrop. Shown whenever viewModel.faceToFaceGroupID is set.
            faceToFaceOverlay
        }
        .animation(.easeOut(duration: 0.25), value: viewModel.hasActiveUndo)
        .animation(.easeOut(duration: 0.25), value: viewModel.transientNotice)
        .animation(.easeOut(duration: 0.25), value: viewModel.pendingRescan)
    }

    // MARK: - Face-to-Face overlay

    @ViewBuilder
    private var faceToFaceOverlay: some View {
        if let id = viewModel.faceToFaceGroupID,
           let group = viewModel.groups.first(where: { $0.id == id }) {
            ZStack {
                // Dimmed, tappable backdrop — click anywhere outside the card to
                // close (the "click out of face-to-face mode" request).
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { closeFaceToFace() }

                FaceToFaceView(
                    group: group,
                    onAccept: { winner in
                        viewModel.selectKeeper(groupID: group.id, itemIndex: winner)
                    },
                    onClose: { closeFaceToFace() },
                    isMaximized: $faceToFaceMaximized
                )
                // Maximized = fill the window edge-to-edge (drop the inset, the
                // rounded corners, and the shadow). Windowed = inset card with a
                // clickable backdrop margin.
                .clipShape(RoundedRectangle(cornerRadius: faceToFaceMaximized ? 0 : 14))
                .shadow(color: .black.opacity(faceToFaceMaximized ? 0 : 0.5), radius: 30)
                .padding(faceToFaceMaximized ? 0 : 24)
            }
            .transition(.opacity)
        }
    }

    /// Closes the comparison overlay and returns keyboard focus to ReviewView so
    /// the j/k/arrow group navigation keeps working afterwards.
    private func closeFaceToFace() {
        viewModel.faceToFaceGroupID = nil
        faceToFaceMaximized = false   // next open starts windowed, not maximized
        isFocused = true
    }

    // MARK: - Sidebar

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Groups (\(viewModel.groups.count))")
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                Spacer()
            }
            Divider()
            List(viewModel.groups, selection: $viewModel.selectedGroupID) { group in
                GroupRow(group: group)
                    .tag(group.id as UUID?)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 320)

            // Staged-set footer: staged groups leave the List above, so without
            // this they'd be invisible until the toolbar flush — the user needs
            // a persistent cue that N groups are set aside plus a way back.
            if !viewModel.stagedGroups.isEmpty {
                Divider()
                HStack {
                    Text("\(viewModel.stagedGroups.count) set aside")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore") {
                        viewModel.restoreStagedGroups()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Move all staged groups back into the review list")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = viewModel.selectedGroupID,
           viewModel.groups.contains(where: { $0.id == id }) {
            GroupDetailView(groupID: id, viewModel: viewModel)
                .id(id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.groups.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Select a group from the sidebar")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.stagedGroups.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.green)
                Text("No duplicate groups found!")
                    .font(.title3.bold())
                Text("Your library looks clean.")
                    .foregroundStyle(.secondary)
                // Closure CTAs. A clean result used to be a dead-end — the user
                // landed here with nothing to click and no obvious way forward
                // (Home lives only in the toolbar, easy to miss when the eye is
                // on this centered card). "Scan Again" replays the exact last
                // scan via `rescan()` (same album/folder/picked-set scope, picking
                // up any setting they've since changed), and "Home" returns to the
                // splash via `reset()`. borderedProminent on Scan Again because a
                // re-scan is the likelier next intent on this screen (e.g. after a
                // settings tweak); plain bordered Home as the secondary exit.
                HStack(spacing: 12) {
                    Button("Scan Again") {
                        viewModel.rescan()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Home") {
                        viewModel.reset()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            }
        } else {
            // Every group was staged rather than found-clean — "library looks
            // clean" here would be wrong (nothing has been deleted yet) and
            // would leave the user without the final flush step.
            VStack(spacing: 16) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)
                Text("All groups reviewed")
                    .font(.title3.bold())
                Text("Click Delete \(viewModel.totalToDelete) Photos to finish in one go.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Delete button

    private var deleteButton: some View {
        Button {
            // Three-way branch on the flush action:
            //   1. "Confirm before delete" ON  → the existing ConfirmDeleteSheet
            //      (the user opted into per-flush friction; honor it).
            //   2. OFF but never-explained-yet → the ONE-TIME-EVER educational
            //      alert below; DON'T delete yet — this is the only moment a
            //      frictionless user is told deletes are immediate-but-recoverable.
            //   3. OFF and already-seen          → frictionless immediate delete,
            //      exactly as the user deliberately configured.
            if AppDefaults.confirmBeforeDelete {
                viewModel.showConfirmDelete = true
            } else if !AppDefaults.hasSeenDeleteInfo {
                showDeleteInfo = true
            } else {
                Task { await viewModel.confirmDelete() }
            }
        } label: {
            // .titleAndIcon FORCES the count text to render. Without it the macOS
            // toolbar collapses a Label to icon-only, leaving a bare red circle
            // with a trash glyph and no hint of how many photos it nukes — the
            // exact ambiguity this button must never have.
            Label("Delete \(viewModel.totalToDelete) Photos", systemImage: "trash")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(viewModel.totalToDelete == 0)
    }

    /// Stages the selected group (`d` key). Deliberately NO confirmation
    /// dialog, even when the "Confirm before delete" setting is ON: staging is
    /// non-destructive (nothing leaves the library or disk), and the final
    /// toolbar flush keeps its confirmation — gating the harmless step too
    /// would just reintroduce the per-group friction staging exists to remove.
    private func stageCurrent() {
        guard let id = viewModel.selectedGroupID,
              let group = viewModel.groups.first(where: { $0.id == id }),
              !group.itemsToDelete.isEmpty else { return }
        viewModel.stageGroup(groupID: id)
    }

    // MARK: - Undo banner

    private var undoBanner: some View {
        // Mixed receipts (assets + files) use the file-style copy: the Undo
        // button restores the files AND opens Photos for the assets anyway.
        let fileStyle = viewModel.lastReceiptHasFileDeletions
        return HStack(spacing: 14) {
            Image(systemName: "trash.circle.fill")
                .font(.title2)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(fileStyle ? "Photos moved to Trash" : "Photos moved to Recently Deleted")
                    .font(.subheadline.bold())
                // Helper copy must match what the button actually does. File
                // undo is a true in-app restore; library "undo" only navigates
                // to Recently Deleted (Apple exposes no programmatic restore),
                // so it promises recovery there, not a put-back here.
                Text(fileStyle
                     ? "Puts the photos back where they were."
                     : "Opens Recently Deleted in Photos, where you can restore them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            // "Recover in Photos" (not "Open Photos"): the library path opens
            // Recently Deleted FOR recovery — a generic "Open Photos" read as
            // "this won't actually get my photos back". File/mixed receipts are
            // a real undo, so they keep "Undo".
            Button(fileStyle ? "Undo" : "Recover in Photos") {
                Task { await viewModel.attemptUndo() }
            }
            .buttonStyle(.bordered)
            Button {
                viewModel.dismissUndoBanner()
            } label: {
                Image(systemName: "xmark")
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            // Icon-only "X": VoiceOver reads .help nowhere, so label it explicitly.
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .frame(maxWidth: 540)
    }

    /// "Settings changed — they apply to a new scan" banner. Shown when the
    /// user edited a scan-affecting setting (timeWindow / pHashThreshold /
    /// closeCallThreshold / scanVideosToo / protectedAlbumIDs) mid-review: those
    /// values are baked into the current results at scan time, so the on-screen
    /// groups can't reflect the change without re-running the pipeline. The
    /// Rescan button replays the exact scan via `viewModel.rescan()`; the "X"
    /// dismisses without rescanning (the user may just be configuring for next
    /// time). Styled like the undo/notice banners for a consistent bottom-stack
    /// look. Kept as its own computed view so ReviewView's body stays under the
    /// Swift type-checker's expression-complexity ceiling (the known SourceKit
    /// slow-type-check warning on this file).
    private var rescanBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.title2)
                .foregroundStyle(.blue)
            Text("Settings changed — they apply to a new scan.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Rescan") {
                viewModel.rescan()
            }
            .buttonStyle(.borderedProminent)
            Button {
                viewModel.pendingRescan = false
            } label: {
                Image(systemName: "xmark")
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            // Icon-only "X": VoiceOver reads .help nowhere, so label it explicitly.
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .frame(maxWidth: 540)
    }

    /// Non-blocking warning toast for partial deletion failures and undo
    /// shortfalls. The view model auto-clears `transientNotice` after ~6 s
    /// (mirroring the undo banner's expiry), but users reported the message
    /// vanished before they finished reading — so the "X" lets them dismiss
    /// (and read) on their own time via `dismissTransientNotice`.
    private func noticeBanner(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                viewModel.dismissTransientNotice()
            } label: {
                Image(systemName: "xmark")
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            // Icon-only "X": VoiceOver reads .help nowhere, so label it explicitly.
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .frame(maxWidth: 540)
    }
}

// MARK: - Group detail

/// Single enum driving ALL sheet presentations in GroupDetailView.
/// Consolidating into one `.sheet(item:)` prevents the "only the last sheet
/// fires" SwiftUI bug that occurred when three separate `.sheet` modifiers
/// were chained on the same ScrollView.
private enum ActiveSheet: Identifiable {
    case lightbox(Int)

    var id: String {
        switch self {
        case .lightbox(let i): return "lightbox-\(i)"
        }
    }
}

struct GroupDetailView: View {
    let groupID: UUID
    @ObservedObject var viewModel: ReviewViewModel
    @State private var activeSheet: ActiveSheet?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var group: PhotoGroup? {
        viewModel.groups.first(where: { $0.id == groupID })
    }

    var body: some View {
        if let group {
            content(for: group)
        }
    }

    private func content(for group: PhotoGroup) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                header(group: group)
                photosGrid(group: group)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Single sheet — avoids "only the last sheet fires" SwiftUI multi-sheet bug.
        // Face-to-Face is intentionally NOT presented here: it's hosted as an
        // in-window overlay at the ReviewView root (so it can toggle native
        // full-screen and be dismissed by clicking the dimmed backdrop), driven
        // by viewModel.faceToFaceGroupID.
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .lightbox(let index):
                PhotoLightboxView(group: group, currentIndex: index)
            }
        }
    }

    // MARK: - Header

    private func header(group: PhotoGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // On compact (iPhone): title on its own line, buttons below.
            // On regular (iPad / Mac): title + buttons on one line.
            if horizontalSizeClass == .compact {
                Text("\(group.items.count) similar photos — keep \(group.keptIndices.count), delete \(group.itemsToDelete.count)")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                detailActionRow(group: group)
            } else {
                HStack(spacing: 8) {
                    Text("\(group.items.count) similar photos — keep \(group.keptIndices.count), delete \(group.itemsToDelete.count)")
                        .font(.headline)
                    Spacer()
                    detailActionRow(group: group)
                }
            }

            if let local = group.localExplanation {
                explanationCard(icon: "eye.fill", color: .blue, label: "Why this one?", text: local)
            }

            // Copy must match the actual gesture wiring in photosGrid: plain tap =
            // sole keeper (the others become deletion candidates), ⌘-click = keep
            // more than one. The ⌘-click clause and the F/D shortcut hints only
            // appear on regular (Mac) width — on compact (iPhone) there's no ⌘ and
            // no keyboard, so advertising either would be a lie.
            Text(horizontalSizeClass != .compact
                 ? "Tap a photo to keep it — the others will be removed. ⌘-click to keep more than one. Press F for side-by-side, D to set aside."
                 : "Tap a photo to keep it — the others will be removed.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // Extracted action buttons so they can be placed either inline (regular width)
    // or below the title (compact width) without duplicating the button definitions.
    @ViewBuilder
    private func detailActionRow(group: PhotoGroup) -> some View {
        HStack(spacing: 8) {
            Button {
                viewModel.faceToFaceGroupID = group.id
            } label: {
                Label("Face-to-Face", systemImage: "rectangle.split.2x1")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)
            .disabled(group.items.count < 2)
            .help("Side-by-side comparison of the top two candidates (F)")

            if !group.itemsToDelete.isEmpty {
                // Stages locally — no confirmation dialog (even with "Confirm
                // before delete" ON) and no red tint: staging is non-destructive,
                // so signaling danger here would be dishonest. The destructive
                // step is the toolbar flush, which keeps both the red tint and
                // its confirmation.
                Button {
                    viewModel.stageGroup(groupID: group.id)
                } label: {
                    Label("Set Aside \(group.itemsToDelete.count)", systemImage: "tray.and.arrow.down")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .help("Set aside for deletion — nothing is deleted until you click Delete in the toolbar")
            }
        }
    }

    private func explanationCard(icon: String, color: Color, label: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.bold())
                    .foregroundStyle(color)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(color.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Responsive grid

    private func photosGrid(group: PhotoGroup) -> some View {
        let count = group.items.count
        let spacing: CGFloat = 10

        // Column strategy — GridItem(.flexible()) is used throughout because it
        // always divides the available pane width equally regardless of window size.
        // GridItem(.adaptive) was tried previously but drops to fewer columns when
        // the pane is narrow, leaving empty horizontal space.
        //
        //   1 photo   → 1 column, fills the pane
        //   2 photos  → 2 equal columns
        //
        //   3+ compact  (iPhone)
        //               → 2 columns; avoids width-inference issues inside the
        //                 collapsed NavigationSplitView stack
        //
        //   3+ regular  (iPad / Mac)
        //               → exactly min(count, 4) columns so photos always span
        //                 the full pane width in a single row (count ≤ 4) or wrap
        //                 into balanced rows (count 5+). Cap at 4 keeps individual
        //                 photos comfortably sized even on narrow layouts.
        let columns: [GridItem]
        let colCount: Int
        switch count {
        case 1:
            colCount = 1
        case 2:
            colCount = 2
        default:
            colCount = horizontalSizeClass == .compact ? 2 : min(count, 4)
        }
        columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: colCount)

        return LazyVGrid(columns: columns, spacing: spacing) {
            ForEach(group.items.indices, id: \.self) { i in
                PhotoCard(
                    item: group.items[i],
                    score: group.displayScores[i],
                    isKeeper: group.keptIndices.contains(i),
                    // Plain tap = make THIS the sole keeper (everything else in the
                    // group becomes a deletion candidate). This matches the on-screen
                    // instruction and the dominant "keep one, delete the rest" flow,
                    // and is consistent with Face-to-Face's "Keep Left/Right" — both
                    // route through selectKeeper. ⌘-click keeps the older multi-keeper
                    // power feature alive via toggleKeep (add/remove without clearing
                    // the rest). selectKeeper/toggleKeep both preserve mandatory
                    // (protected/undecodable) keepers, so neither gesture can delete
                    // something that must be kept.
                    onTap: { viewModel.selectKeeper(groupID: group.id, itemIndex: i) },
                    onModifierTap: { viewModel.toggleKeep(groupID: group.id, itemIndex: i) },
                    onDoubleTap: { activeSheet = .lightbox(i) }
                )
            }
        }
        // Single-photo groups would otherwise stretch one full-pane-wide column,
        // leaving a lone tile awkwardly orphaned at the left of a wide window. Cap
        // its width at a comfortable 520pt and center it. Multi-photo groups keep
        // the original full-width left-aligned layout untouched: the explicit
        // max-width still lets the flexible columns measure against the full pane.
        .frame(
            maxWidth: count == 1 ? 520 : .infinity,
            alignment: count == 1 ? .center : .leading
        )
        .frame(maxWidth: .infinity, alignment: count == 1 ? .center : .leading)
    }
}

// NOTE: PhotoGroup intentionally does NOT conform to Equatable.
//
// `.sheet(item:)` and List selection only require Identifiable (already
// satisfied by `let id = UUID()`). An id-only `Equatable` conformance is a
// SwiftUI footgun: views that store `let group: PhotoGroup` (GroupRow in the
// sidebar, PhotoLightboxView, FaceToFaceView) are diffed via that `==`, so a
// group whose `keptIndices` changed reads as "unchanged" (same id) and the row
// never re-renders — the "−N" / "Keep X of Y" badges go stale even though the
// underlying data updated. Without the conformance, SwiftUI's structural diff
// compares the stored fields (incl. `keptIndices`) and re-renders correctly.

// MARK: - Keyboard-shortcut legend

/// Content of the toolbar "?" popover: a compact, single-glance reference for
/// every review-screen shortcut.
///
/// Kept as its own view struct (not an inline `@ViewBuilder` on ReviewView) for
/// two reasons: (1) it keeps ReviewView's already-large body/toolbar under the
/// Swift type-checker's expression-complexity ceiling — the known SourceKit
/// "unable to type-check in reasonable time" warning on this file — and (2) the
/// rows are pure static data, so isolating them documents that this view holds
/// no app state and never needs to re-render.
///
/// The wording here MUST stay in sync with the actual key handlers in
/// ReviewView.body (.onKeyPress for j/k/arrows/Return/1–9/d/f, the hidden ⌘Z
/// button, .onExitCommand for Esc) and the gesture wiring in PhotoCard (plain
/// tap = sole keeper, ⌘-click = multi-keep, double-tap = lightbox). If those
/// change, change these strings too — a stale cheat sheet is worse than none.
private struct ShortcutLegend: View {
    /// (action, keys) pairs rendered as aligned label/key rows. Order roughly
    /// follows the review flow: navigate → choose keepers → set aside / compare
    /// → inspect → undo/dismiss.
    private let rows: [(action: String, keys: String)] = [
        ("Next / previous group", "J / K  or  ↓ / ↑"),
        ("Next group", "Return"),
        ("Keep photo 1–9", "1 – 9"),
        ("Keep one (the rest are removed)", "Tap"),
        ("Keep several", "⌘-click"),
        ("Set group aside for deletion", "D"),
        ("Side-by-side compare", "F"),
        ("Full-size view", "Double-click"),
        ("Undo last delete", "⌘Z"),
        ("Close overlay", "Esc"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keyboard Shortcuts")
                .font(.headline)

            // Grid keeps the keys column right-aligned and vertically aligned
            // across rows regardless of action-label length — a plain HStack
            // stack would leave the keys raggedly placed.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(rows, id: \.action) { row in
                    GridRow {
                        Text(row.action)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .gridColumnAlignment(.leading)
                        // Monospaced digits keep the key glyphs from jittering
                        // column width between rows; secondary color reads them
                        // as "the key" against the primary action text.
                        Text(row.keys)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
        }
        .padding(16)
        // Fixed width so the popover doesn't size to its widest row and jump
        // around; ~320pt comfortably fits the longest action label.
        .frame(width: 320, alignment: .leading)
    }
}

// MARK: - Scan-settings snapshot

/// A value snapshot of exactly the AppDefaults that affect a scan's RESULTS:
/// the grouping/scoring thresholds plus the two inputs that change which items
/// are even considered (videos on/off, protected albums). ReviewView captures
/// one when opening Settings mid-review and asks it `changedSinceSnapshot()` on
/// dismissal — if anything moved, the current on-screen groups are stale and a
/// rescan banner is offered.
///
/// Why these five and not all of Settings: `confirmBeforeDelete` and
/// `holdForReview` change only what DELETING does, never what the scan finds,
/// so editing them must NOT nag the user to rescan. Keeping the list explicit
/// (rather than diffing the whole defaults dictionary) is the whole point — it
/// encodes precisely which knobs invalidate results. If a future setting starts
/// affecting grouping/scoring, add it here AND to `runPipeline`'s reads.
private struct ScanSettingsSnapshot: Equatable {
    let timeWindow: Double
    let pHashThreshold: Int
    let closeCallThreshold: Double
    let scanVideosToo: Bool
    let protectedAlbumIDs: [String]

    static func current() -> ScanSettingsSnapshot {
        ScanSettingsSnapshot(
            timeWindow: AppDefaults.timeWindow,
            pHashThreshold: AppDefaults.pHashThreshold,
            closeCallThreshold: AppDefaults.closeCallThreshold,
            scanVideosToo: AppDefaults.scanVideosToo,
            protectedAlbumIDs: AppDefaults.protectedAlbumIDs
        )
    }

    /// True iff any captured value differs from the live AppDefaults now —
    /// i.e. the user saved a scan-affecting change while Settings was open.
    /// Order-sensitive on protectedAlbumIDs is acceptable: the picker only ever
    /// appends/removes, so a real edit always changes contents, and a spurious
    /// reorder (which the picker can't produce) merely offers a harmless rescan.
    func changedSinceSnapshot() -> Bool {
        self != ScanSettingsSnapshot.current()
    }
}
