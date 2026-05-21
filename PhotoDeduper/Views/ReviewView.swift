import SwiftUI
import Photos

struct ReviewView: View {
    @ObservedObject var viewModel: ReviewViewModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    viewModel.reset()
                } label: {
                    Label("Home", systemImage: "house")
                }
                .help("Return to Home")
            }
            ToolbarItem(placement: .automatic) {
                reviewAllButton
            }
            ToolbarItem(placement: .primaryAction) {
                deleteButton
            }
        }
        .sheet(isPresented: $viewModel.showConfirmDelete) {
            ConfirmDeleteSheet(viewModel: viewModel)
        }
        .navigationTitle("Photo Deduper")
    }

    // MARK: - Sidebar

    private var sidebar: some View {
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
        }
        .frame(width: 260)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = viewModel.selectedGroupID,
           viewModel.groups.contains(where: { $0.id == id }) {
            GroupDetailView(groupID: id, viewModel: viewModel)
                .id(id)                          // re-mount view on selection change
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

    // MARK: - Album-wide AI review

    @ViewBuilder
    private var reviewAllButton: some View {
        let isPaidUser = UserDefaults.standard.bool(forKey: "isPaidUser")
        let providers = activeProviders()
        let isReviewingAny = viewModel.groups.contains(where: { $0.isAIReviewing })

        if isPaidUser, !providers.isEmpty, !viewModel.groups.isEmpty {
            if providers.count == 1 {
                let p = providers[0]
                Button {
                    Task { await viewModel.requestAIReviewForAllGroups(provider: p) }
                } label: {
                    Label("Review all with \(p.displayName)", systemImage: p.systemImage)
                }
                .disabled(isReviewingAny)
                .help("Run \(p.displayName) on every group")
            } else {
                Menu {
                    ForEach(providers) { p in
                        Button {
                            Task { await viewModel.requestAIReviewForAllGroups(provider: p) }
                        } label: {
                            Label("Review all with \(p.displayName)", systemImage: p.systemImage)
                        }
                    }
                    Divider()
                    Button {
                        for p in providers {
                            Task { await viewModel.requestAIReviewForAllGroups(provider: p) }
                        }
                    } label: {
                        Label("Review all with every provider", systemImage: "arrow.triangle.2.circlepath")
                    }
                } label: {
                    Label("Review All", systemImage: "sparkles")
                }
                .disabled(isReviewingAny)
                .help("Run AI review across every group in this album")
            }
        }
    }

    /// Which AI providers the user currently has keys for, in display order.
    /// Returned as an ordered array so single-provider UI can index providers[0].
    fileprivate func activeProviders() -> [AIProvider] {
        var list: [AIProvider] = []
        if !(KeychainHelper.retrieve(key: "claude_api_key") ?? "").isEmpty { list.append(.claude) }
        if !(KeychainHelper.retrieve(key: "openai_api_key") ?? "").isEmpty { list.append(.openai) }
        if !(KeychainHelper.retrieve(key: "groq_api_key")   ?? "").isEmpty { list.append(.groq) }
        return list
    }
}

// MARK: - Group detail

private struct LightboxTarget: Identifiable {
    let id = UUID()
    let index: Int
}

struct GroupDetailView: View {
    let groupID: UUID
    @ObservedObject var viewModel: ReviewViewModel
    @State private var lightboxTarget: LightboxTarget?
    @State private var showDeleteConfirmation = false

    /// Look up by stable id — tolerates the underlying array being reordered or emptied
    /// (e.g. during `viewModel.reset()` or `deleteGroup`) without crashing.
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
        }
        .sheet(item: $lightboxTarget) { target in
            PhotoLightboxView(group: group, currentIndex: target.index)
        }
    }

    // MARK: - Header

    private func header(group: PhotoGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(group.items.count) similar photos — keep \(group.keptIndices.count), delete \(group.itemsToDelete.count)")
                    .font(.headline)
                Spacer()
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
                aiMenuButton(group: group)
            }

            if let explanation = group.claudeExplanation {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.purple)
                    Text("Auto-review: \(explanation)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.purple.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            ForEach(AIProvider.allCases) { provider in
                if let result = group.aiReviews[provider.rawValue] {
                    AIReviewCard(result: result, photoNumber: result.winnerIndex + 1) {
                        viewModel.acceptAISuggestion(groupID: group.id, provider: provider)
                    }
                } else if let errorMsg = group.aiErrors[provider.rawValue] {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.subheadline)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(provider.displayName) review failed")
                                .font(.subheadline.bold())
                            Text(errorMsg)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(.orange.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            if group.isAIReviewing {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.75)
                    Text("AI is reviewing…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Click the expand icon in the corner of a photo to view full size")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func aiMenuButton(group: PhotoGroup) -> some View {
        let isPaidUser = UserDefaults.standard.bool(forKey: "isPaidUser")
        let providers = activeProvidersForGroup()

        if isPaidUser, !providers.isEmpty {
            if providers.count == 1 {
                // Single provider — no dropdown needed; render a direct button.
                let p = providers[0]
                Button {
                    Task { await viewModel.requestAIReview(groupID: group.id, provider: p) }
                } label: {
                    Label("Ask \(p.displayName)", systemImage: p.systemImage)
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .disabled(group.isAIReviewing)
            } else {
                Menu {
                    ForEach(providers) { p in
                        Button {
                            Task { await viewModel.requestAIReview(groupID: group.id, provider: p) }
                        } label: {
                            Label("Ask \(p.displayName)", systemImage: p.systemImage)
                        }
                    }
                    Divider()
                    Button {
                        for p in providers {
                            Task { await viewModel.requestAIReview(groupID: group.id, provider: p) }
                        }
                    } label: {
                        Label("Ask All", systemImage: "arrow.triangle.2.circlepath")
                    }
                } label: {
                    Label("Ask AI", systemImage: "sparkles")
                        .font(.subheadline)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(group.isAIReviewing)
            }
        }
    }

    private func activeProvidersForGroup() -> [AIProvider] {
        var list: [AIProvider] = []
        if !(KeychainHelper.retrieve(key: "claude_api_key") ?? "").isEmpty { list.append(.claude) }
        if !(KeychainHelper.retrieve(key: "openai_api_key") ?? "").isEmpty { list.append(.openai) }
        if !(KeychainHelper.retrieve(key: "groq_api_key")   ?? "").isEmpty { list.append(.groq) }
        return list
    }

    // MARK: - Responsive grid that fills the panel width

    private func photosGrid(group: PhotoGroup) -> some View {
        let count = group.items.count
        // Use 2 columns for small groups so photos are large; cap at 4.
        let colCount = count <= 2 ? count : min(count, 4)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: colCount)

        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(group.items.indices, id: \.self) { i in
                PhotoCard(
                    item: group.items[i],
                    score: group.displayScores[i],
                    isKeeper: group.keptIndices.contains(i),
                    onTap: { viewModel.toggleKeep(groupID: group.id, itemIndex: i) },
                    onDoubleTap: { lightboxTarget = LightboxTarget(index: i) }
                )
            }
        }
    }
}

// MARK: - AI Review Card

private struct AIReviewCard: View {
    let result: AIReviewResult
    let photoNumber: Int
    let onAccept: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.provider.systemImage)
                .foregroundStyle(result.provider.accentColor)
                .font(.subheadline)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(result.provider.displayName) recommends photo \(photoNumber)")
                        .font(.subheadline.bold())
                    Spacer()
                    Button("Accept", action: onAccept)
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Text(result.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(result.provider.accentColor.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
