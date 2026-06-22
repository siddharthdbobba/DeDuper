import SwiftUI
import Photos
import CoreGraphics
import ImageIO

struct PhotoCard: View {
    let item: PhotoItem
    let score: Double
    let isKeeper: Bool
    let onTap: () -> Void
    /// Optional alternate action for a modifier-held tap (macOS ⌘-click). When
    /// set, the grid uses plain tap = "make this the sole keeper" and ⌘-click =
    /// "toggle this in/out of the keeper set" (the multi-keep power feature),
    /// keeping the dominant keep-one-delete-the-rest gesture honest with the copy
    /// while preserving multi-select. Falls back to `onTap` when nil.
    var onModifierTap: (() -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil
    /// On-device "Why this one?" reason for the keeper (sharpness veto, close-call
    /// tie-break, or protection). Set only on the proposed keeper so the
    /// explanation sits directly on the chosen photo — important when the keeper
    /// isn't the highest-scoring one. nil on every other card.
    var explanation: String? = nil

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
                // Deletion candidates are marked by the red border + DELETE badge
                // alone — no dimming overlay, so the photo stays fully inspectable.
                PhotoThumbnail(item: item, displayQuality: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            // ── Decorations (outside the clip so they render on the boundary) ──
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(borderColor, lineWidth: isKeeper ? 4 : 1.5)
            )
            .overlay(alignment: .topTrailing) { statusBadge }
            .overlay(alignment: .topLeading)  { topLeftBadges }
            .overlay(alignment: .bottomLeading) { bottomLeadingBadge }
            .overlay(alignment: .bottomTrailing) {
                if onDoubleTap != nil { zoomButton }
            }
            .shadow(color: isKeeper ? .green.opacity(0.30) : .clear, radius: 8)
            .scaleEffect(isKeeper ? 1.0 : 0.97)
            .animation(.easeOut(duration: 0.15), value: isKeeper)
            // Gesture precedence is load-bearing here. The ⌘-modified TapGesture
            // uses `.highPriorityGesture` so that when ⌘ is held it WINS outright
            // and the plain `.onTapGesture` below does NOT also fire — otherwise a
            // ⌘-click would run both `onModifierTap` (toggle) AND `onTap` (collapse
            // to sole keeper), silently defeating multi-keep. With ⌘ up the modified
            // gesture can't match (`.modifiers(.command)`), so the plain tap is the
            // sole behavior and still fires `onTap`. On platforms without ⌘ (iOS)
            // the modified gesture never matches, leaving plain tap as the only path.
            .highPriorityGesture(TapGesture().modifiers(.command).onEnded { (onModifierTap ?? onTap)() })
            .onTapGesture { onTap() }
            // VoiceOver: collapse the tile (image + stacked badges + zoom button)
            // into ONE element so a screen reader announces a single coherent
            // "Photo to keep, 87 percent, tap to keep this one" instead of reading
            // each decorative badge as a separate, contextless control. The label
            // leads with the decision the user cares about (keep / delete /
            // protected — the same three-way the border + statusBadge encode
            // visually), the value carries the quality score sighted users read
            // off scoreBadge, and the hint states the dominant plain-tap action.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(item.isProtected ? "Protected photo" : (isKeeper ? "Photo to keep" : "Photo to delete"))
            .accessibilityValue(accessibilityValueText)
            .accessibilityHint("Tap to keep this one and remove the others")
    }

    /// Reads the quality score, and — on the keeper — the reason it was chosen, so
    /// VoiceOver explains a lower-scoring keeper the same way the on-card banner
    /// does for sighted users.
    private var accessibilityValueText: String {
        let pct = "Quality score \(String(format: "%.0f", score * 100)) percent"
        if isKeeper, let explanation, !explanation.isEmpty {
            return "\(pct). Why this one? \(explanation)"
        }
        return pct
    }

    private var borderColor: Color {
        if item.isProtected { return .blue }
        return isKeeper ? .green : .red.opacity(0.55)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if item.isProtected {
            capsuleBadge("Protected", systemImage: "lock.fill", color: .blue)
        } else if isKeeper {
            capsuleBadge("KEEP", systemImage: "checkmark.circle.fill", color: .green)
        } else {
            capsuleBadge("DELETE", systemImage: "trash.fill", color: .red)
        }
    }

    private func capsuleBadge(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color)
            .foregroundStyle(.white)
            .clipShape(Capsule())
            .padding(8)
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

    /// On the keeper, the score pill grows into a small card that also carries the
    /// "Why this one?" reason — so when the chosen photo isn't the highest-scoring
    /// one, the explanation sits right on the picked photo instead of only in the
    /// header. Every other card (and a keeper with no reason) keeps the plain pill.
    @ViewBuilder
    private var bottomLeadingBadge: some View {
        if isKeeper, let explanation, !explanation.isEmpty {
            keeperScoreReasonBar(explanation)
        } else {
            scoreBadge
        }
    }

    private func keeperScoreReasonBar(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                Text(String(format: "%.1f%%", score * 100)).font(.caption.bold())
            }
            Label(reason, systemImage: "eye.fill")
                .font(.caption2.bold())
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.black.opacity(0.72))
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // Cap the width so a long reason wraps to a second line instead of running
        // across the card into the trailing zoom button.
        .frame(maxWidth: 240, alignment: .leading)
        .padding(8)
        .help("Why this one? \(reason)")
    }

    private var scoreBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
            Text(String(format: "%.1f%%", score * 100)).font(.caption.bold())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        // 0.72 (was 0.55): over a bright, blown-out photo the thinner scrim let
        // the white "XX.X%" wash out and fail contrast. The darker fill keeps the
        // percent legible on any background without making the capsule look opaque.
        .background(.black.opacity(0.72))
        .foregroundStyle(.white)
        .clipShape(Capsule())
        .padding(8)
        // The "XX.X%" reads as a mystery number without this — a star + percent
        // looks like a rating but says nothing about what's being rated or why
        // one photo got picked over its near-identical neighbor. Spell out the
        // inputs (the same signals PhotoScorer weighs) AND the consequence so a
        // hover answers both "what is this?" and "why does it matter?". The keeper
        // isn't always the highest-scoring photo — a sharper or better-faced shot
        // can win — so the copy points to the on-keeper "Why this one?" note.
        .help("Quality score — sharpness, exposure, and composition. Higher is better. The app usually keeps the highest-scoring photo, but may pick a sharper or better-faced shot — the keeper shows a “Why this one?” note when it does.")
    }

    private var zoomButton: some View {
        Button { onDoubleTap?() } label: {
            // The glyph itself stays small (~20pt) so it sits unobtrusively in the
            // corner, but the tappable region is expanded to the 44pt minimum:
            // a min 44×44 frame + .contentShape(Rectangle()) makes the whole
            // square hit-test, not just the tiny visible circle. .topTrailing
            // pins the small glyph to the corner of that larger frame so the card
            // doesn't visually balloon — only the touch target grows.
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption2)
                .padding(5)
                .background(.black.opacity(0.45))
                .foregroundStyle(.white)
                .clipShape(Circle())
                .frame(minWidth: 44, minHeight: 44, alignment: .topTrailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(8)
        .help("View full size")
        // .help is a hover tooltip only — VoiceOver never reads it, so without
        // this the icon-only button announces as "button" with no purpose.
        .accessibilityLabel("View full size")
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
    /// When true, loads a crisp display-resolution image (~1400 px) instead of the
    /// small 400/600 px compact thumbnail. Used by the review grid (`PhotoCard`) so
    /// each candidate is sharp enough to judge at a glance. It deliberately does NOT
    /// decode the full-resolution original — that made the grid slow; true full-res
    /// inspection lives in the lightbox. The compact sidebar thumbnails (`GroupRow`)
    /// leave this off to stay on the smallest/fastest path.
    var displayQuality: Bool = false
    @State private var image: PlatformImage?
    @State private var requestID: PHImageRequestID?
    /// The item id the most recent load was started for. Used to drop stale
    /// completions: comparing against `self.item.id` inside a completion closure
    /// would be useless — the closure captures this view struct BY VALUE, so that
    /// read is frozen at request time and always matches. @State storage, by
    /// contrast, is shared across all copies of the view for the same identity,
    /// so reading it in the closure sees the CURRENT value.
    @State private var loadedForID: String?

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
        .onChange(of: item.id) {
            // A reused cell (e.g. LazyVGrid recycling) whose item changed must
            // drop the in-flight request and reload for the new item.
            cancelInFlightRequest()
            image = nil
            load()
        }
        .onDisappear(perform: cancelInFlightRequest)
    }

    private func cancelInFlightRequest() {
        if let id = requestID {
            ThumbnailCache.shared.cancelRequest(id)
            requestID = nil
        }
    }

    private func load() {
        loadedForID = item.id
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
        // PHImageManager's opportunistic delivery calls this handler multiple
        // times (degraded → final), and a late callback can land after the cell
        // was recycled for a different item. Compare the id captured at request
        // time against `loadedForID` (see its doc comment for why `self.item.id`
        // can't serve as the "current" side of this check).
        let requestedID = item.id
        let handler: (PlatformImage?) -> Void = { image in
            if let image {
                Task { @MainActor in
                    guard loadedForID == requestedID else { return } // stale callback
                    self.image = image
                }
            }
        }
        requestID = displayQuality
            ? ThumbnailCache.shared.requestDisplayImage(for: asset, completion: handler)
            : ThumbnailCache.shared.requestImage(for: asset, completion: handler)
    }

    private func loadFromFileURL(_ url: URL) {
        // Downsample directly off the image source. For the grid we cap at ~1400 px
        // (sharp on retina) instead of fully decoding the original file — a full
        // decode of a 24 MP JPEG/HEIC per card was the folder-scan equivalent of the
        // slow asset path. ImageIO downsampling decodes only what it needs.
        let maxPixel: CGFloat = displayQuality ? 1400 : 400
        let requestedID = item.id
        Task.detached(priority: .userInitiated) {
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }

            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
            let opts: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return }
            let img = PlatformImage.from(cgImage: cg)
            await MainActor.run {
                guard loadedForID == requestedID else { return } // stale: cell was reused
                self.image = img
            }
        }
    }

    private func loadVideoThumbnail(_ url: URL) {
        // Videos have no still "original"; a larger keyframe keeps the review grid
        // crisp, while the compact path stays small.
        let side: CGFloat = displayQuality ? 1400 : 800
        let requestedID = item.id
        Task.detached(priority: .userInitiated) {
            let item = await PhotoLibraryManager.loadThumbnail(for: PhotoItem.from(url: url), size: CGSize(width: side, height: side))
            guard let cg = item else { return }
            let img = PlatformImage.from(cgImage: cg)
            await MainActor.run {
                guard loadedForID == requestedID else { return } // stale: cell was reused
                self.image = img
            }
        }
    }
}
