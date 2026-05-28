import SwiftUI
import Photos
import CoreGraphics
import ImageIO

struct PhotoCard: View {
    let item: PhotoItem
    let score: Double
    let isKeeper: Bool
    let onTap: () -> Void
    var onDoubleTap: (() -> Void)? = nil

    var body: some View {
        // ── Layout anchor ─────────────────────────────────────────────────────
        // Color.clear has zero intrinsic size, so the aspectRatio modifier has
        // sole control of the card's height. Using the photo's natural width:height
        // ratio makes the card match the actual photo shape (portrait, landscape,
        // square). Falls back to 1:1 for videos and unresolved dimensions.
        Color.clear
            .aspectRatio(item.aspectRatio, contentMode: .fit)
            // ── Image + dim effect (all clipped together to the rounded rect) ──
            .overlay {
                ZStack {
                    PhotoThumbnail(item: item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Dim deletion candidates so the keeper visually wins at a
                    // glance. Must live inside this overlay so clipShape below
                    // correctly masks its corners (not just the thumbnail).
                    if !isKeeper {
                        Color.black.opacity(0.32)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            // ── Decorations (outside the clip so they render on the boundary) ──
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(borderColor, lineWidth: isKeeper ? 4 : 1.5)
            )
            .overlay(alignment: .topTrailing) { statusBadge }
            .overlay(alignment: .topLeading)  { topLeftBadges }
            .overlay(alignment: .bottomLeading) { scoreBadge }
            .overlay(alignment: .bottomTrailing) {
                if onDoubleTap != nil { zoomButton }
            }
            .shadow(color: isKeeper ? .green.opacity(0.30) : .clear, radius: 8)
            .scaleEffect(isKeeper ? 1.0 : 0.97)
            .animation(.easeOut(duration: 0.15), value: isKeeper)
            .onTapGesture { onTap() }
    }

    private var borderColor: Color {
        if item.isProtected { return .blue }
        return isKeeper ? .green : .red.opacity(0.55)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if item.isProtected {
            Label("Protected", systemImage: "lock.fill")
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.blue)
                .foregroundStyle(.white)
                .clipShape(Capsule())
                .padding(8)
        } else if isKeeper {
            Label("KEEP", systemImage: "checkmark.circle.fill")
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.green)
                .foregroundStyle(.white)
                .clipShape(Capsule())
                .padding(8)
        } else {
            Label("DELETE", systemImage: "trash.fill")
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.red)
                .foregroundStyle(.white)
                .clipShape(Capsule())
                .padding(8)
        }
    }

    @ViewBuilder
    private var topLeftBadges: some View {
        HStack(spacing: 4) {
            if item.isVideo {
                Image(systemName: "play.fill")
                    .font(.caption2)
                    .padding(5)
                    .background(.black.opacity(0.55))
                    .foregroundStyle(.white)
                    .clipShape(Circle())
            }
            if item.burstIdentifier != nil {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.caption2)
                    .padding(5)
                    .background(.black.opacity(0.55))
                    .foregroundStyle(.white)
                    .clipShape(Circle())
                    .help("Burst photo")
            }
        }
        .padding(8)
    }

    private var scoreBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
            Text(String(format: "%.1f%%", score * 100)).font(.caption.bold())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55))
        .foregroundStyle(.white)
        .clipShape(Capsule())
        .padding(8)
    }

    private var zoomButton: some View {
        Button { onDoubleTap?() } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption2)
                .padding(5)
                .background(.black.opacity(0.45))
                .foregroundStyle(.white)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(8)
        .help("View full size")
    }
}

// MARK: - Async thumbnail that handles both PHAsset and file URL

struct PhotoThumbnail: View {
    let item: PhotoItem
    /// `.fit` (default) preserves the photo's natural aspect ratio — used in the
    /// main review grid where each card sizes itself to match the photo shape.
    /// `.fill` crops to fill a fixed frame — used in compact sidebar thumbnails
    /// (GroupRow) where a 52×52 square looks better than a letterboxed image.
    var contentMode: ContentMode = .fit
    @State private var image: PlatformImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        Group {
            if let image {
                if contentMode == .fill {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                }
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        // Avoid scaleEffect on ProgressView — AppKit's NSProgressIndicator
                        // bridge produces fractional min==max AutoLayout constraints when
                        // a scale transform is applied, triggering layout-recursion warnings.
                        // Using a fixed frame instead avoids the constraint violation entirely.
                        ProgressView()
                            .frame(width: 20, height: 20)
                    }
            }
        }
        .onAppear(perform: load)
        .onDisappear {
            if let id = requestID {
                ThumbnailCache.shared.cancelRequest(id)
                requestID = nil
            }
        }
    }

    private func load() {
        switch item.source {
        case .asset(let asset):
            loadFromAsset(asset)
        case .fileURL(let url):
            if item.isVideo {
                loadVideoThumbnail(url)
            } else {
                loadFromFileURL(url)
            }
        }
    }

    private func loadFromAsset(_ asset: PHAsset) {
        requestID = ThumbnailCache.shared.requestImage(for: asset) { image in
            if let image {
                Task { @MainActor in self.image = image }
            }
        }
    }

    private func loadFromFileURL(_ url: URL) {
        Task.detached(priority: .userInitiated) {
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }

            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
            let opts: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: 400,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return }
            let img = PlatformImage.from(cgImage: cg)
            await MainActor.run { self.image = img }
        }
    }

    private func loadVideoThumbnail(_ url: URL) {
        Task.detached(priority: .userInitiated) {
            let item = await PhotoLibraryManager.loadThumbnail(for: PhotoItem.from(url: url), size: CGSize(width: 800, height: 800))
            guard let cg = item else { return }
            let img = PlatformImage.from(cgImage: cg)
            await MainActor.run { self.image = img }
        }
    }
}
