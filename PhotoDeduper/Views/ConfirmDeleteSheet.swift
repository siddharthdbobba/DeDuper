import SwiftUI

struct ConfirmDeleteSheet: View {
    @ObservedObject var viewModel: ReviewViewModel
    @Environment(\.dismiss) private var dismiss

    private var isHoldForReview: Bool {
        UserDefaults.standard.bool(forKey: "holdForReview")
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: isHoldForReview ? "tray.full" : "trash.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(isHoldForReview ? .blue : .red)

            Text(isHoldForReview ? "Stage for Review" : "Confirm Deletion")
                .font(.title2.bold())

            statsGrid

            if isHoldForReview {
                Text("These photos will be added to a **\(BatchDeleteManager.reviewAlbumName)** album in Photos. They stay in your library; you can audit them later and delete from there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Deleted photos move to **Recently Deleted** and can be recovered for 30 days. File-system images move to the macOS Trash.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 14) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)

                Button(isHoldForReview ? "Stage \(viewModel.totalToDelete) Photos" : "Delete \(viewModel.totalToDelete) Photos") {
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
            statRow("Photos to delete", "\(viewModel.totalToDelete)")
            Divider()
            statRow("Groups to keep", "\(viewModel.groups.count)")
            Divider()
            statRow(
                "Estimated space freed",
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
