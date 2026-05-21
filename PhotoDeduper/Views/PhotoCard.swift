import SwiftUI
import Photos
import AppKit
import CoreGraphics
import ImageIO

struct PhotoCard: View {
    let item: PhotoItem
    let score: Double
    let isKeeper: Bool
    let onTap: () -> Void
    var onDoubleTap: (() -> Void)? = nil

    var body: some View {
        PhotoThumbnail(item: item)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isKeeper ? Color.green : Color.red.opacity(0.55),
                            lineWidth: isKeeper ? 3 : 1.5)
            )
            .overlay(alignment: .topTrailing) { statusBadge }
            .overlay(alignment: .bottomLeading) { scoreBadge }
            .overlay(alignment: .bottomTrailing) {
                if onDoubleTap != nil { zoomButton }
            }
            .shadow(color: isKeeper ? .green.opacity(0.25) : .clear, radius: 6)
            // Single .onTapGesture only — adding a count: 2 recognizer here would
            // force SwiftUI to wait NSEvent.doubleClickInterval (~300ms) before
            // firing onTap. The zoomButton overlay handles "open lightbox" instead.
            .onTapGesture { onTap() }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isKeeper {
            Label("Keep", systemImage: "checkmark.circle.fill")
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.green)
                .foregroundStyle(.white)
                .clipShape(Capsule())
                .padding(8)
        } else {
            Label("Remove", systemImage: "trash.fill")
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.red)
                .foregroundStyle(.white)
                .clipShape(Capsule())
                .padding(8)
        }
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
    @State private var image: NSImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay { ProgressView().scaleEffect(0.6) }
            }
        }
        .onAppear(perform: load)
        .onDisappear {
            if let id = requestID {
                PHImageManager.default().cancelImageRequest(id)
                requestID = nil
            }
        }
    }

    private func load() {
        switch item.source {
        case .asset(let asset):
            loadFromAsset(asset)
        case .fileURL(let url):
            loadFromFileURL(url)
        }
    }

    private func loadFromAsset(_ asset: PHAsset) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true

        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 800, height: 800),
            contentMode: .aspectFill,
            options: options
        ) { nsImage, _ in
            if let nsImage {
                Task { @MainActor in self.image = nsImage }
            }
        }
    }

    private func loadFromFileURL(_ url: URL) {
        Task.detached(priority: .userInitiated) {
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }

            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
            let opts: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: 800,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return }
            let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            await MainActor.run { self.image = ns }
        }
    }
}
