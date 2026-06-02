import SwiftUI
import Photos

struct GroupRow: View {
    let group: PhotoGroup

    var body: some View {
        HStack(spacing: 10) {
            PhotoThumbnail(item: group.items[group.primaryKeeperIndex], contentMode: .fill)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if group.containsProtected {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .padding(3)
                            .background(.blue)
                            .foregroundStyle(.white)
                            .clipShape(Circle())
                            .padding(2)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("Keep \(group.keptIndices.count) of \(group.items.count)")
                        .font(.subheadline.bold())
                    originBadge
                }
                if let date = group.items.first?.creationDate {
                    Text(date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 4) {
                if group.itemsToDelete.count > 0 {
                    Text("−\(group.itemsToDelete.count)")
                        .font(.caption.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.red.opacity(0.12))
                        .foregroundStyle(.red)
                        .clipShape(Capsule())
                }

                if group.localExplanation != nil {
                    Image(systemName: "eye.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .help("On-device face analysis decided")
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var originBadge: some View {
        switch group.origin {
        case .timeWindow:
            EmptyView()
        case .burst:
            Text("BURST")
                .font(.caption2.bold())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.orange.opacity(0.15))
                .foregroundStyle(.orange)
                .clipShape(Capsule())
        case .video:
            Text("VIDEO")
                .font(.caption2.bold())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.pink.opacity(0.15))
                .foregroundStyle(.pink)
                .clipShape(Capsule())
        }
    }
}
