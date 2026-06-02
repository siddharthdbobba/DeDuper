import SwiftUI
import Photos

struct ReviewView: View {
    @ObservedObject var viewModel: ReviewViewModel
    @FocusState private var isFocused: Bool
    /// Set to a group ID when the `d` shortcut is pressed; drives the per-group
    /// confirmation dialog so accidental keypresses don't immediately delete.
    @State private var confirmDeleteGroupID: UUID?
    /// Whether the Face-to-Face overlay fills the window edge-to-edge — its own
    /// in-app "full screen", distinct from the app window's native full-screen.
    @State private var faceToFaceMaximized = false

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
                }
                ToolbarItem(placement: .primaryAction) {
                    deleteButton
                }
            }
            .sheet(isPresented: $viewModel.showConfirmDelete) {
                ConfirmDeleteSheet(viewModel: viewModel)
            }
            .confirmationDialog(
                {
                    if let id = confirmDeleteGroupID,
                       let g = viewModel.groups.first(where: { $0.id == id }) {
                        return "Delete \(g.itemsToDelete.count) photo\(g.itemsToDelete.count == 1 ? "" : "s")?"
                    }
                    return "Delete?"
                }(),
                isPresented: Binding(
                    get: { confirmDeleteGroupID != nil },
                    set: { if !$0 { confirmDeleteGroupID = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let id = confirmDeleteGroupID {
                        Task { await viewModel.deleteGroup(groupID: id) }
                    }
                    confirmDeleteGroupID = nil
                }
            } message: {
                Text("Deleted photos move to Recently Deleted and can be recovered for 30 days.")
            }
            .navigationTitle("DeDuper")
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onAppear { isFocused = true }
            .onKeyPress(.return)   { viewModel.selectNextGroup(); return .handled }
            .onKeyPress(.downArrow){ viewModel.selectNextGroup(); return .handled }
            .onKeyPress(.upArrow)  { viewModel.selectPreviousGroup(); return .handled }
            .onKeyPress("j")       { viewModel.selectNextGroup(); return .handled }
            .onKeyPress("k")       { viewModel.selectPreviousGroup(); return .handled }
            .onKeyPress("d")       { deleteCurrent(); return .handled }
            .onKeyPress("f") {
                if let id = viewModel.selectedGroupID,
                   let group = viewModel.groups.first(where: { $0.id == id }),
                   group.items.count >= 2 {
                    viewModel.faceToFaceGroupID = id
                }
                return .handled
            }
            .onKeyPress { press in
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

            if viewModel.hasActiveUndo {
                undoBanner
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 16)
            }

            // Face-to-Face comparison — hosted at the window root (not as a sheet)
            // so it can toggle native full-screen and be dismissed by clicking the
            // dimmed backdrop. Shown whenever viewModel.faceToFaceGroupID is set.
            faceToFaceOverlay
        }
        .animation(.easeOut(duration: 0.25), value: viewModel.hasActiveUndo)
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

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            Text("No duplicate groups found!")
                .font(.title3.bold())
            Text("Your library looks clean.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Delete button

    private var deleteButton: some View {
        Button {
            viewModel.showConfirmDelete = true
        } label: {
            Label("Delete \(viewModel.totalToDelete) Photos", systemImage: "trash")
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(viewModel.totalToDelete == 0)
    }

    private func deleteCurrent() {
        guard let id = viewModel.selectedGroupID,
              let group = viewModel.groups.first(where: { $0.id == id }),
              !group.itemsToDelete.isEmpty else { return }
        // Show confirmation dialog — keyboard shortcuts must not bypass safety checks.
        confirmDeleteGroupID = id
    }

    // MARK: - Undo banner

    private var undoBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "trash.circle.fill")
                .font(.title2)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Photos moved to Recently Deleted")
                    .font(.subheadline.bold())
                Text("Recoverable for 30 days in Photos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Open Photos") {
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
    @State private var showDeleteConfirmation = false
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

            Text("Tap a photo to select it as the keeper.\(horizontalSizeClass != .compact ? " Press F for side-by-side, Return to delete this group." : "")")
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
                Button {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete \(group.itemsToDelete.count)", systemImage: "trash")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .confirmationDialog(
                    "Delete \(group.itemsToDelete.count) photo\(group.itemsToDelete.count == 1 ? "" : "s")?",
                    isPresented: $showDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        Task { await viewModel.deleteGroup(groupID: group.id) }
                    }
                } message: {
                    Text("Deleted photos move to Recently Deleted and can be recovered for 30 days.")
                }
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
                    onTap: { viewModel.toggleKeep(groupID: group.id, itemIndex: i) },
                    onDoubleTap: { activeSheet = .lightbox(i) }
                )
            }
        }
        // Explicit max-width so adaptive columns always measure against the full
        // available pane width rather than the grid's own content width.
        .frame(maxWidth: .infinity, alignment: .leading)
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
