import SwiftUI

struct DoneView: View {
    let keptCount: Int
    let deletedCount: Int
    let freedBytes: Int64
    @ObservedObject var viewModel: ReviewViewModel

    private var isHoldForReview: Bool {
        UserDefaults.standard.bool(forKey: "holdForReview")
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

            Text(isHoldForReview
                 ? "Open Photos to audit the staged album; remove from there when you're ready."
                 : "Deleted photos are in **Recently Deleted** and can be recovered for 30 days.")
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

                if viewModel.lastReceipt != nil {
                    Button {
                        Task { await viewModel.attemptUndo() }
                    } label: {
                        Label("Open Photos", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help("Opens Photos so you can confirm and recover from Recently Deleted")
                }
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
