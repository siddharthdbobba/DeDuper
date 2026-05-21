import SwiftUI
import Photos

struct GroupRow: View {
    let group: PhotoGroup

    var body: some View {
        HStack(spacing: 10) {
            PhotoThumbnail(item: group.items[group.primaryKeeperIndex])
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text("Keep \(group.keptIndices.count) of \(group.items.count)")
                    .font(.subheadline.bold())
                if let date = group.items.first?.creationDate {
                    Text(date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 4) {
                Text("−\(group.itemsToDelete.count)")
                    .font(.caption.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.red.opacity(0.12))
                    .foregroundStyle(.red)
                    .clipShape(Capsule())

                if group.claudeExplanation != nil {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
