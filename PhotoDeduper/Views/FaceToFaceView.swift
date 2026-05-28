import SwiftUI
import Photos

/// Full-screen side-by-side comparison of any two photos in a group, with
/// synchronised pan/zoom and arrow-key cycling. Inspired by PhotoSweeper's
/// "Face-to-Face" mode — the single most-praised feature in PhotoSweeper reviews.
struct FaceToFaceView: View {
    let group: PhotoGroup
    let onAccept: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var leftIndex: Int
    @State private var rightIndex: Int

    // ── Zoom / pan state ─────────────────────────────────────────────────────
    /// Committed zoom level between gestures.
    @State private var zoom: CGFloat = 1.0
    /// Committed pan offset between drags/zooms. Always clamped to bounds.
    @State private var pan: CGSize = .zero
    /// Live drag delta (auto-resets to .zero via @GestureState when finger lifts).
    @GestureState private var dragOffset: CGSize = .zero
    /// Live pinch scale factor (auto-resets to 1.0 via @GestureState on release).
    @GestureState private var magnifyBy: CGFloat = 1.0
    /// Size of the full comparison pane, tracked so pan bounds stay accurate
    /// as the window resizes. Updated via .task(id: geo.size) inside GeometryReader.
    @State private var containerSize: CGSize = .zero

    @StateObject private var imageCache = LightboxImageCache()
    @FocusState private var isFocused: Bool

    init(group: PhotoGroup, onAccept: @escaping (Int) -> Void) {
        self.group = group
        self.onAccept = onAccept
        // Default to top two by score; fall back to distinct indices when possible.
        let ranked = group.scores.indices.sorted { group.scores[$0] > group.scores[$1] }
        let first  = ranked.first ?? 0
        let second: Int
        if ranked.count > 1 {
            second = ranked[1]
        } else if group.items.count > 1 {
            second = first == 0 ? 1 : 0
        } else {
            second = first
        }
        _leftIndex  = State(initialValue: first)
        _rightIndex = State(initialValue: second)
    }

    // MARK: - Derived zoom / pan

    /// Zoom factoring in the live pinch gesture, clamped to [1, 6].
    private var liveZoom: CGFloat {
        max(1.0, min(6.0, zoom * magnifyBy))
    }

    /// Committed + live drag delta, clamped so the image can't be dragged
    /// completely outside the pane.
    private var effectivePan: CGSize {
        clampedPan(
            CGSize(width: pan.width + dragOffset.width,
                   height: pan.height + dragOffset.height),
            forZoom: liveZoom
        )
    }

    /// Returns `pan` clamped so neither image can be dragged off-screen.
    ///
    /// The key is using the *fitted* image dimensions (after scaledToFit inside
    /// the pane), not the raw pane dimensions. A 16:9 landscape photo in a
    /// portrait pane only occupies `paneW × (paneW / 1.78)` pixels at zoom 1,
    /// not the full `paneW × paneH`. Allowing `paneH × (z−1)/2` of vertical
    /// pan would let the user drag the image completely out of view.
    ///
    /// For each axis:  maxPan = max(0, (fittedDim × z − paneDim) / 2)
    ///
    /// Because pan is shared by both panes we take the *minimum* of the two
    /// images' bounds — this keeps both in view simultaneously. For duplicate
    /// photos (always the same aspect ratio) the two values are identical.
    private func clampedPan(_ pan: CGSize, forZoom z: CGFloat) -> CGSize {
        let paneW = max(1, (containerSize.width - 2) / 2)
        let paneH = max(1, containerSize.height)

        // Fitted size of an item after scaledToFit inside one pane.
        func fitted(_ item: PhotoItem) -> CGSize {
            let ar = max(0.001, item.aspectRatio)   // w / h
            return paneW / paneH >= ar
                ? CGSize(width: paneH * ar, height: paneH)   // fits by height
                : CGSize(width: paneW,      height: paneW / ar) // fits by width
        }

        let safeL = max(0, min(leftIndex,  group.items.count - 1))
        let safeR = max(0, min(rightIndex, group.items.count - 1))
        let lf = fitted(group.items[safeL])
        let rf = fitted(group.items[safeR])

        // Tighter bound of the two images in each axis.
        let maxX = max(0, (min(lf.width,  rf.width)  * z - paneW) / 2)
        let maxY = max(0, (min(lf.height, rf.height) * z - paneH) / 2)

        return CGSize(
            width:  max(-maxX, min(maxX, pan.width)),
            height: max(-maxY, min(maxY, pan.height))
        )
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                comparisonPane
                bottomBar
            }
        }
#if os(macOS)
        .frame(minWidth: 880, idealWidth: 1200, maxWidth: .infinity,
               minHeight: 600, idealHeight: 800, maxHeight: .infinity)
#else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#endif
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear { isFocused = true }
        .onKeyPress { press in
            guard press.modifiers.isEmpty else { return .ignored }
            switch press.characters {
            case "1": onAccept(leftIndex); dismiss(); return .handled
            case "2": onAccept(rightIndex); dismiss(); return .handled
            case "0": resetView(); return .handled
            case "+", "=": zoomIn(); return .handled
            case "-", "_": zoomOut(); return .handled
            default: return .ignored
            }
        }
        .onKeyPress(.leftArrow)  { cycle(side: .left,  by: -1); return .handled }
        .onKeyPress(.rightArrow) { cycle(side: .left,  by: +1); return .handled }
        .onKeyPress(.upArrow)    { cycle(side: .right, by: -1); return .handled }
        .onKeyPress(.downArrow)  { cycle(side: .right, by: +1); return .handled }
        .onKeyPress(.escape)     { dismiss(); return .handled }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Spacer()
            VStack(spacing: 2) {
                Text("Face-to-Face")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Photo \(leftIndex + 1) vs \(rightIndex + 1) of \(group.items.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()

            HStack(spacing: 8) {
                // ── Zoom controls ─────────────────────────────────────────────
                Button { zoomOut() } label: {
                    Image(systemName: "minus.magnifyingglass").foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(zoom <= 1.0)

                Text(String(format: "%.0f%%", liveZoom * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 50)

                Button { zoomIn() } label: {
                    Image(systemName: "plus.magnifyingglass").foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(zoom >= 6.0)

                // Reset: arrow.counterclockwise so it's clearly "undo/reset",
                // not confused with the expand/fullscreen icon.
                Button { resetView() } label: {
                    Image(systemName: "arrow.counterclockwise.circle")
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Reset zoom & pan (0)")
                .disabled(zoom == 1.0 && pan == .zero)

#if os(macOS)
                // Full-screen toggle: puts the host window (and therefore this
                // sheet) into macOS full-screen mode so photos fill the display.
                Button {
                    NSApplication.shared.keyWindow?.toggleFullScreen(nil)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Toggle full screen (⌃⌘F)")
#endif
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Comparison pane

    private var comparisonPane: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                pane(index: leftIndex,  label: "1", containerSize: geo.size)
                pane(index: rightIndex, label: "2", containerSize: geo.size)
            }
            .background(.black)
            // Track container size so clampedPan stays accurate on window resize.
            .task(id: geo.size) { containerSize = geo.size }
#if os(macOS)
            // Transparent overlay that captures trackpad two-finger scroll events
            // and forwards them as pan deltas. SwiftUI's DragGesture only handles
            // mouse click-drag; trackpad swipe generates scrollWheel AppKit events
            // which this NSView intercepts.
            .overlay(
                TrackpadScrollCapture { delta in
                    pan = clampedPan(
                        CGSize(width: pan.width + delta.x, height: pan.height + delta.y),
                        forZoom: liveZoom
                    )
                }
            )
#endif
        }
    }

    private func pane(index: Int, label: String, containerSize: CGSize) -> some View {
        // Clamp stale indices defensively (group can be mutated by a parallel AI review).
        let safeIndex = max(0, min(index, group.items.count - 1))

        return ZStack(alignment: .topLeading) {
            Color.black
            SyncedPhotoView(
                item: group.items[safeIndex],
                cache: imageCache,
                zoom: liveZoom,
                pan: effectivePan
            )

            // Label bubble + score
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(label)
                        .font(.title3.bold())
                        .frame(width: 28, height: 28)
                        .background(.white)
                        .foregroundStyle(.black)
                        .clipShape(Circle())
                    if group.keptIndices.contains(safeIndex) {
                        Label("Current keeper", systemImage: "checkmark.circle.fill")
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.green)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    if group.items[safeIndex].isProtected {
                        Label("Protected", systemImage: "lock.fill")
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.blue)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                }
                if safeIndex < group.displayScores.count {
                    Text(String(format: "Score %.1f%%", group.displayScores[safeIndex] * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(12)
            .allowsHitTesting(false)

            // Accept button — bottom trailing
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        onAccept(safeIndex)
                        dismiss()
                    } label: {
                        Label("Keep this one (\(label))", systemImage: "checkmark.circle")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.green)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                }
            }
        }
        .frame(width: max(0, (containerSize.width - 2) / 2),
               height: containerSize.height)
        .contentShape(Rectangle())
        .clipped()
        // Drag and pinch recognised simultaneously so two-finger pan + pinch
        // work together without one gesture cancelling the other.
        .gesture(panGesture.simultaneously(with: magnificationGesture))
    }

    // MARK: - Gestures

    /// Drag gesture: transient delta lives in @GestureState (auto-resets on lift);
    /// onEnded commits the total translation into `pan` with bounds clamping.
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($dragOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                pan = clampedPan(
                    CGSize(width:  pan.width  + value.translation.width,
                           height: pan.height + value.translation.height),
                    forZoom: zoom
                )
            }
    }

    /// Pinch/magnification gesture: responds to trackpad pinch and touch pinch.
    /// Live multiplier lives in @GestureState (auto-resets to 1.0 on release);
    /// onEnded commits the final zoom level with bounds clamping on pan.
    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .updating($magnifyBy) { value, state, _ in
                state = value
            }
            .onEnded { value in
                let newZoom = max(1.0, min(6.0, zoom * value))
                zoom = newZoom
                // Re-clamp pan: zooming out may have shrunk the valid range.
                pan = clampedPan(pan, forZoom: newZoom)
            }
    }

    // MARK: - Zoom / pan controls

    private func zoomIn() {
        let newZoom = min(6.0, zoom + 0.5)
        zoom = newZoom
        pan = clampedPan(pan, forZoom: newZoom)
    }

    private func zoomOut() {
        let newZoom = max(1.0, zoom - 0.5)
        zoom = newZoom
        if newZoom == 1.0 { pan = .zero } else { pan = clampedPan(pan, forZoom: newZoom) }
    }

    private func resetView() {
        withAnimation(.easeOut(duration: 0.2)) {
            zoom = 1.0
            pan  = .zero
        }
    }

    // MARK: - Photo cycling

    private enum Side { case left, right }

    private func cycle(side: Side, by delta: Int) {
        let n = group.items.count
        guard n >= 2 else { return }
        switch side {
        case .left:
            var next = (leftIndex + delta + n) % n
            if next == rightIndex {
                next = (next + (delta >= 0 ? 1 : -1) + n) % n
            }
            leftIndex = next
        case .right:
            var next = (rightIndex + delta + n) % n
            if next == leftIndex {
                next = (next + (delta >= 0 ? 1 : -1) + n) % n
            }
            rightIndex = next
        }
        // Reset pan on photo switch; keep zoom so the user can compare the same detail.
        pan = .zero
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            Text("**1** keep left · **2** keep right · **← →** cycle left · **↑ ↓** cycle right · **+/−** zoom · **0** reset · **Esc** close")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black)
    }
}

// MARK: - Synced zoom/pan image

private struct SyncedPhotoView: View {
    let item: PhotoItem
    @ObservedObject var cache: LightboxImageCache
    let zoom: CGFloat
    let pan: CGSize

    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom)
                    .offset(pan)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            } else {
                ProgressView().tint(.white)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) {
            if let cached = cache.cached(for: item) {
                image = cached
                return
            }
            image = await cache.load(item: item)
        }
    }
}

// MARK: - Trackpad scroll capture (macOS only)

#if os(macOS)
import AppKit

/// Transparent NSView overlay that forwards trackpad two-finger swipe events
/// to SwiftUI as pan deltas.
///
/// SwiftUI's DragGesture only handles mouse click-drag; trackpad two-finger
/// swipe generates `scrollWheel` AppKit events. This thin wrapper intercepts
/// those events without blocking any SwiftUI gestures (drag / pinch travel
/// through separate AppKit event channels).
///
/// Delta sign convention (matches "natural scrolling" where content follows
/// fingers):
///   • Swipe RIGHT  → positive x  → pan.width  increases → image moves right
///   • Swipe DOWN   → negative y  → pan.height decreases → image moves up
///     (trackpad scrollingDeltaY is positive for "scroll up" in AppKit terms,
///      i.e. content should appear to move DOWN, so we negate to get the image
///      moving in the same direction as the fingers.)
private struct TrackpadScrollCapture: NSViewRepresentable {
    var onScroll: (CGPoint) -> Void

    func makeNSView(context: Context) -> ScrollCaptureView {
        let v = ScrollCaptureView()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ nsView: ScrollCaptureView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class ScrollCaptureView: NSView {
        var onScroll: ((CGPoint) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            // Only precise (trackpad) events — ignore mouse wheel steps.
            guard event.hasPreciseScrollingDeltas else {
                super.scrollWheel(with: event)
                return
            }
            // Ignore momentum (finger-off deceleration) so panning stops
            // cleanly when fingers lift rather than coasting unpredictably.
            guard event.momentumPhase.rawValue == 0 else { return }

            // scrollingDeltaY > 0 means AppKit "scroll up" (show content above)
            // which translates to moving the image DOWN — so negate Y.
            onScroll?(CGPoint(
                x:  event.scrollingDeltaX,
                y: -event.scrollingDeltaY
            ))
        }
    }
}
#endif
