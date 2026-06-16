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
                        // Stay on one line: in a dragged-narrow sidebar or at large
                        // accessibility text sizes this would otherwise wrap mid-
                        // phrase ("Keep 2 of / 7") next to the origin badge. One
                        // clean truncation reads better than an awkward two-line wrap.
                        .lineLimit(1)
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
                    // Colorblind cue: the badge was red-fill + red-text only, so a
                    // red/green-impaired user couldn't tell "−N to delete" from a
                    // neutral count. Prefixing a trash glyph encodes "for deletion"
                    // in shape, not just hue. Kept compact (small icon font, tight
                    // padding) so the row stays the same height.
                    Label("\(group.itemsToDelete.count)", systemImage: "trash")
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
                        // The static "face analysis decided" copy lied for the
                        // sharpness-veto case: the SAME icon shows when the
                        // resolver kept the sharper copy (no faces involved), so
                        // a face-specific tooltip there was just wrong. Surface
                        // the group's ACTUAL localExplanation (the same text the
                        // detail pane's "Why this one?" card shows), falling back
                        // to a neutral phrasing only if it's somehow nil despite
                        // the `!= nil` guard above.
                        .help(group.localExplanation ?? "On-device analysis picked the keeper")
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
