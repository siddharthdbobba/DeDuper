import SwiftUI

struct ConfirmDeleteSheet: View {
    @ObservedObject var viewModel: ReviewViewModel
    @Environment(\.dismiss) private var dismiss

    private var isHoldForReview: Bool {
        AppDefaults.holdForReview
    }

    private var title: String {
        if isHoldForReview {
            return viewModel.isFolderScan ? "Leave Files in Place" : "Move to Review Album"
        }
        return "Confirm Deletion"
    }

    private var primaryButtonLabel: String {
        if isHoldForReview {
            return viewModel.isFolderScan
                ? "Leave \(viewModel.totalToDelete) in Place"
                : "Move \(viewModel.totalToDelete) to Review Album"
        }
        return "Delete \(viewModel.totalToDelete) Photos"
    }

    private var explanatoryCopy: String {
        if isHoldForReview {
            return viewModel.isFolderScan
                ? "These folder images will be left in place. Nothing on disk will be deleted, and disk files are not moved to a Photos album."
                : "These photos will be added to a **\(BatchDeleteManager.reviewAlbumName)** album in Photos. They stay in your library; you can audit them later and delete from there."
        }
        return "Deleted photos move to **Recently Deleted** and can be recovered for 30 days. File-system images move to the macOS Trash."
    }

    private var estimatedSpaceLabel: String {
        isHoldForReview ? "Potential space to free" : "Estimated space freed"
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: isHoldForReview ? "tray.full" : "trash.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(isHoldForReview ? .blue : .red)

            // Library hold mode says "Move to Review Album" (not "Stage") so it
            // doesn't collide with the app's local "Set Aside" vocabulary.
            Text(title)
                .font(.title2.bold())

            statsGrid

            Text(LocalizedStringKey(explanatoryCopy))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 14) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)

                Button(primaryButtonLabel) {
                    dismiss()
                    Task { await viewModel.confirmDelete() }
                }
                .buttonStyle(.borderedProminent)
                .tint(isHoldForReview ? .blue : .red)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(36)
        .frame(width: 460)
    }

    private var statsGrid: some View {
        VStack(spacing: 0) {
            statRow(isHoldForReview ? "Photos selected" : "Photos to delete", "\(viewModel.totalToDelete)")
            Divider()
            // Staged groups keep their keepers too — the flush only deletes
            // each group's itemsToDelete — so they count as kept groups here.
            // (totalToDelete / estimatedFreedBytes already span both sets.)
            statRow("Groups to keep", "\(viewModel.groups.count + viewModel.stagedGroups.count)")
            Divider()
            statRow(
                estimatedSpaceLabel,
                ByteCountFormatter.string(fromByteCount: viewModel.estimatedFreedBytes, countStyle: .file)
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).bold()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
