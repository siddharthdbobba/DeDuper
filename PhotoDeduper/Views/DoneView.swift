import SwiftUI

struct DoneView: View {
    let keptCount: Int
    let deletedCount: Int
    let freedBytes: Int64
    @ObservedObject var viewModel: ReviewViewModel

    private var isHoldForReview: Bool {
        AppDefaults.holdForReview
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 90))
                .foregroundStyle(.green)

            VStack(spacing: 6) {
                Text(isHoldForReview ? "Staged for review!" : "All done!")
                    .font(.largeTitle.bold())
                Text(isHoldForReview ? "Photos are in your Photos library under \"\(BatchDeleteManager.reviewAlbumName)\"." : "Your library is cleaner now.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            statsCard

            if viewModel.lastDeleteFailedCount > 0 {
                // Partial-failure accounting: the stats above only count what
                // actually left the disk/library; this row owns the remainder
                // so failed files don't silently disappear from the summary.
                // Promoted from a thin one-liner to a tinted warning row (icon
                // + bolder text in an orange card): a user scrolling the success
                // stats was missing the small line, so "N files couldn't be
                // deleted" now reads as a clear, can't-miss warning.
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    Text("\(viewModel.lastDeleteFailedCount) file\(viewModel.lastDeleteFailedCount == 1 ? "" : "s") couldn't be deleted")
                        .font(.callout.bold())
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 380)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.35), lineWidth: 1)
                )
            }

            Text(isHoldForReview
                 ? "Open Photos to audit the staged album; remove from there when you're ready."
                 : (viewModel.isFolderScan
                    ? "Deleted photos are in the **macOS Trash**."
                    : "Deleted photos are in **Recently Deleted** and can be recovered for 30 days."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: 12) {
                Button { viewModel.reset() } label: {
                    Label("Home", systemImage: "house")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                // Return goes Home (not Undo) — undoing a delete should stay a
                // deliberate click, never an accidental keypress.
                .keyboardShortcut(.defaultAction)

                // Gate on `canUndoLastDelete` (≡ lastReceipt != nil), NOT the
                // in-review banner's `hasActiveUndo` countdown: a user sitting
                // on this success screen should be able to undo for as long as
                // the receipt is actionable (files still in Trash / assets in
                // Recently Deleted), without a hidden 120s timer pulling the
                // button out from under them.
                if viewModel.canUndoLastDelete {
                    Button {
                        Task { await viewModel.attemptUndo() }
                    } label: {
                        // "Recover in Photos" (not "Open Photos"): library-only
                        // deletes open Recently Deleted FOR recovery — see the
                        // matching rationale on ReviewView's undo banner. File/
                        // mixed receipts are a real put-back, so they read "Undo".
                        Label(viewModel.lastReceiptHasFileDeletions ? "Undo" : "Recover in Photos",
                              systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help(viewModel.lastReceiptHasFileDeletions
                          ? "Puts the photos back where they were."
                          : "Opens Recently Deleted in Photos, where you can restore them.")
                }
            }

            if let notice = viewModel.transientNotice {
                // Undo outcomes (e.g. "files are no longer in the Trash") must
                // surface here too — the Undo button above can fail after the
                // review screen (and its toast) is already gone.
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var statsCard: some View {
        VStack(spacing: 0) {
            statRow(icon: isHoldForReview ? "tray.full" : "trash.fill",
                    label: isHoldForReview ? "Photos staged" : "Photos deleted",
                    value: "\(deletedCount)", color: .red)
            Divider().padding(.leading, 44)
            statRow(icon: "photo.stack.fill", label: "Photos kept", value: "\(keptCount)", color: .blue)
            Divider().padding(.leading, 44)
            statRow(
                icon: "externaldrive.fill",
                label: isHoldForReview ? "Estimated space to free" : "Space freed",
                value: ByteCountFormatter.string(fromByteCount: freedBytes, countStyle: .file),
                color: .green
            )
        }
        .frame(maxWidth: 380)
        .background(.background.shadow(.drop(color: .black.opacity(0.06), radius: 8, y: 2)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func statRow(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 22)
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value).bold()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}
