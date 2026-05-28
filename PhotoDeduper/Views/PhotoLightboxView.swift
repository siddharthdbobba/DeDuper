import SwiftUI
import Photos
import ImageIO

struct PhotoLightboxView: View {
    let group: PhotoGroup
    @State var currentIndex: Int

    @Environment(\.dismiss) private var dismiss
    /// Without an explicitly-focused container, the sheet's focus lands on the close
    /// button and arrow keys never reach `.onKeyPress` on the ZStack.
    @FocusState private var isFocused: Bool
    @StateObject private var imageCache = LightboxImageCache()
    @State private var showInfo: Bool = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Backdrop — tapping anywhere on the black area dismisses (or closes
            // the info panel if it's open).
            Color.black.ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    if showInfo {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            showInfo = false
                        }
                    } else {
                        dismiss()
                    }
                }

            VStack(spacing: 0) {
                topBar
                imageArea
                bottomBar
            }

            if showInfo {
                PhotoInfoPanel(item: group.items[currentIndex]) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        showInfo = false
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
            }
        }
#if os(macOS)
        .frame(minWidth: 960, maxWidth: .infinity, minHeight: 720, maxHeight: .infinity)
#else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#endif
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear {
            isFocused = true
            prefetchNeighbors()
        }
        .onChange(of: currentIndex) { _, _ in
            prefetchNeighbors()
        }
        // Swipe up to reveal info, swipe down to hide — the trackpad-native
        // equivalent of the Apple Photos swipe-for-info gesture.
        .gesture(infoSwipeGesture)
        // Keyboard navigation
        .onKeyPress(.leftArrow)  { navigate(-1) }
        .onKeyPress(.rightArrow) { navigate(+1) }
        .onKeyPress(.upArrow) {
            guard !showInfo else { return .ignored }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showInfo = true }
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard showInfo else { return .ignored }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showInfo = false }
            return .handled
        }
        .onKeyPress("i") {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showInfo.toggle() }
            return .handled
        }
        .onKeyPress(.escape) {
            if showInfo {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showInfo = false }
                return .handled
            }
            dismiss()
            return .handled
        }
    }

    /// Drag-up reveals the info panel; drag-down dismisses it. minimumDistance is
    /// large enough that taps still register on the backdrop's tap gesture.
    private var infoSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let dy = value.translation.height
                if dy < -40 && !showInfo {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        showInfo = true
                    }
                } else if dy > 40 && showInfo {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        showInfo = false
                    }
                }
            }
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

            Text("\(currentIndex + 1) / \(group.items.count)")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .monospacedDigit()

            Spacer()

            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    showInfo.toggle()
                }
            } label: {
                Image(systemName: showInfo ? "info.circle.fill" : "info.circle")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Show photo info (i, or swipe up)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Image area with prev/next arrows

    private var imageArea: some View {
        ZStack {
            FullSizePhotoView(item: group.items[currentIndex], cache: imageCache)
                .id(group.items[currentIndex].id)

            HStack {
                navButton(systemImage: "chevron.left.circle.fill", enabled: currentIndex > 0) {
                    navigate(-1)
                }
                Spacer()
                navButton(systemImage: "chevron.right.circle.fill", enabled: currentIndex < group.items.count - 1) {
                    navigate(+1)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func navButton(systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 38))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white.opacity(enabled ? 0.85 : 0.2))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 20) {
            // Score
            HStack(spacing: 4) {
                Image(systemName: "star.fill").foregroundStyle(.yellow)
                Text(String(format: "Score: %.1f%%", group.displayScores[currentIndex] * 100))
            }
            .font(.subheadline)

            // Keeper status
            if group.keptIndices.contains(currentIndex) {
                Label("Keeping this photo", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline.bold())
            } else {
                Label("Marked for removal", systemImage: "trash")
                    .foregroundStyle(.red.opacity(0.8))
                    .font(.subheadline)
            }

            Spacer()

            // Dot indicators
            HStack(spacing: 6) {
                ForEach(group.items.indices, id: \.self) { i in
                    Circle()
                        .fill(i == currentIndex ? Color.white : Color.white.opacity(0.3))
                        .frame(width: i == currentIndex ? 8 : 6, height: i == currentIndex ? 8 : 6)
                        .onTapGesture { currentIndex = i }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.black.opacity(0.4))
    }

    // MARK: - Navigation

    @discardableResult
    private func navigate(_ delta: Int) -> KeyPress.Result {
        let next = currentIndex + delta
        guard next >= 0, next < group.items.count else { return .ignored }
        currentIndex = next
        return .handled
    }

    /// Kicks off async loads for the photos immediately before/after the current one,
    /// so arrow-key navigation is served instantly from the cache.
    private func prefetchNeighbors() {
        for delta in [-1, 1, -2, 2] {
            let idx = currentIndex + delta
            guard idx >= 0, idx < group.items.count else { continue }
            imageCache.prefetch(item: group.items[idx])
        }
    }
}

// MARK: - In-memory cache for lightbox-resolution images

@MainActor
final class LightboxImageCache: ObservableObject {
    private let cache = NSCache<NSString, PlatformImage>()
    private var inFlight: Set<String> = []

    init() {
        // Keep a small window: current + immediate neighbors. NSImage at 3840px is
        // heavy (~40-60 MB decoded), so we bound by count rather than by bytes.
        cache.countLimit = 8
    }

    func cached(for item: PhotoItem) -> PlatformImage? {
        cache.object(forKey: item.id as NSString)
    }

    /// Returns the cached image or loads it now. Cached results are returned synchronously.
    func load(item: PhotoItem) async -> PlatformImage? {
        if let img = cached(for: item) { return img }
        let img = await loadFromSource(item)
        if let img { cache.setObject(img, forKey: item.id as NSString) }
        return img
    }

    /// Fire-and-forget load; safe to call repeatedly. Coalesces concurrent requests
    /// for the same item.
    func prefetch(item: PhotoItem) {
        if cached(for: item) != nil { return }
        if inFlight.contains(item.id) { return }
        inFlight.insert(item.id)
        Task { [weak self] in
            guard let self else { return }
            let img = await self.loadFromSource(item)
            if let img { self.cache.setObject(img, forKey: item.id as NSString) }
            self.inFlight.remove(item.id)
        }
    }

    private func loadFromSource(_ item: PhotoItem) async -> PlatformImage? {
        switch item.source {
        case .asset(let asset): return await loadAsset(asset)
        case .fileURL(let url): return await loadFile(url)
        }
    }

    private func loadAsset(_ asset: PHAsset) async -> PlatformImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 3840, height: 3840),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }

    private func loadFile(_ url: URL) async -> PlatformImage? {
        await Task.detached(priority: .userInitiated) {
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            return PlatformImage(contentsOfFile: url.path)
        }.value
    }
}

// MARK: - Photo info panel (swipe-up sheet)

struct PhotoInfoPanel: View {
    let item: PhotoItem
    let onClose: () -> Void
    @State private var metadata: PhotoMetadata?

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle / dismiss affordance
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: 40, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    dateSection
                    cameraSection
                    fileSection
                    locationSection

                    if metadata == nil {
                        HStack {
                            Spacer()
                            ProgressView().tint(.white)
                            Spacer()
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 360)
        .background(
            // Frosted dark backdrop matching Apple Photos' info sheet
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.35)
            }
            .ignoresSafeArea(edges: .bottom)
        )
        .preferredColorScheme(.dark)
        .task(id: item.id) {
            metadata = nil
            metadata = await PhotoMetadataLoader.shared.load(for: item)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var dateSection: some View {
        if let date = metadata?.date {
            VStack(alignment: .leading, spacing: 2) {
                Text(date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text(date.formatted(.dateTime.hour().minute()))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    @ViewBuilder
    private var cameraSection: some View {
        let hasCamera = metadata?.cameraMake != nil
            || metadata?.cameraModel != nil
            || metadata?.lens != nil
            || metadata?.aperture != nil
            || metadata?.iso != nil

        if hasCamera {
            VStack(alignment: .leading, spacing: 10) {
                Label("Camera", systemImage: "camera.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))

                if let combined = formattedCamera() {
                    Text(combined)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                }
                if let lens = metadata?.lens {
                    Text(lens)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                }

                if let settings = formattedShotSettings() {
                    Text(settings)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.top, 2)
                }
            }
            .padding(.top, 4)
        }
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("File", systemImage: "doc.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))

            if let filename = metadata?.filename {
                infoRow(label: "Name", value: filename)
            }
            if let dim = metadata?.dimensions {
                let w = Int(dim.width), h = Int(dim.height)
                let mp = Double(w * h) / 1_000_000
                infoRow(label: "Dimensions", value: "\(w) × \(h)  •  \(String(format: "%.1f MP", mp))")
            }
            if let size = metadata?.fileSize {
                infoRow(label: "Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
        }
    }

    @ViewBuilder
    private var locationSection: some View {
        if let loc = metadata?.location {
            VStack(alignment: .leading, spacing: 8) {
                Label("Location", systemImage: "location.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                infoRow(
                    label: "Coordinates",
                    value: String(format: "%.5f, %.5f", loc.latitude, loc.longitude)
                )
            }
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    // MARK: Formatting helpers

    private func formattedCamera() -> String? {
        let make  = metadata?.cameraMake?.trimmingCharacters(in: .whitespaces)
        let model = metadata?.cameraModel?.trimmingCharacters(in: .whitespaces)
        // Many cameras include the make as a prefix in the model field already.
        if let model, !model.isEmpty {
            if let make, !make.isEmpty, !model.lowercased().hasPrefix(make.lowercased()) {
                return "\(make) \(model)"
            }
            return model
        }
        return make
    }

    private func formattedShotSettings() -> String? {
        var parts: [String] = []
        if let focal = metadata?.focalLength {
            parts.append("\(Int(focal.rounded()))mm")
        }
        if let aperture = metadata?.aperture {
            parts.append("ƒ/\(String(format: "%.1f", aperture))")
        }
        if let shutter = metadata?.shutterSpeed {
            parts.append(shutter)
        }
        if let iso = metadata?.iso {
            parts.append("ISO \(iso)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  •  ")
    }
}

// MARK: - Photo metadata model + loader

struct PhotoMetadata {
    var filename: String?
    var date: Date?
    var fileSize: Int64?
    var dimensions: CGSize?
    var cameraMake: String?
    var cameraModel: String?
    var lens: String?
    var aperture: Double?
    var shutterSpeed: String?
    var iso: Int?
    var focalLength: Double?
    var location: (latitude: Double, longitude: Double)?
}

/// Loads EXIF / file details on demand. Results are cached so re-opening the panel
/// or arrow-keying back to a photo is instant.
actor PhotoMetadataLoader {
    static let shared = PhotoMetadataLoader()
    private var cache: [String: PhotoMetadata] = [:]

    func load(for item: PhotoItem) async -> PhotoMetadata {
        if let cached = cache[item.id] { return cached }
        let result = await fetch(item: item)
        cache[item.id] = result
        return result
    }

    private func fetch(item: PhotoItem) async -> PhotoMetadata {
        switch item.source {
        case .asset(let asset): return await fetchAsset(asset)
        case .fileURL(let url): return await fetchFile(url)
        }
    }

    private func fetchAsset(_ asset: PHAsset) async -> PhotoMetadata {
        var meta = PhotoMetadata()
        meta.date = asset.creationDate
        meta.dimensions = CGSize(width: asset.pixelWidth, height: asset.pixelHeight)
        if let loc = asset.location {
            meta.location = (loc.coordinate.latitude, loc.coordinate.longitude)
        }

        // Filename + on-disk size from the underlying PHAssetResource.
        let resources = PHAssetResource.assetResources(for: asset)
        if let primary = resources.first(where: { $0.type == .photo }) ?? resources.first {
            meta.filename = primary.originalFilename
            if let s = primary.value(forKey: "fileSize") as? Int64 {
                meta.fileSize = s
            } else if let s = primary.value(forKey: "fileSize") as? Int {
                meta.fileSize = Int64(s)
            }
        }

        // EXIF via PHContentEditingInput — gives a file URL we can read with
        // CGImageSource without decoding the pixels.
        if let props = await requestExif(for: asset) {
            parseExif(props, into: &meta)
        }
        return meta
    }

    private func fetchFile(_ url: URL) async -> PhotoMetadata {
        var meta = PhotoMetadata()
        meta.filename = url.lastPathComponent

        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            meta.fileSize = (attrs[.size] as? NSNumber)?.int64Value
            meta.date = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date)
        }

        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
            if let w = props[kCGImagePropertyPixelWidth as String] as? Int,
               let h = props[kCGImagePropertyPixelHeight as String] as? Int {
                meta.dimensions = CGSize(width: w, height: h)
            }
            parseExif(props, into: &meta)
        }
        return meta
    }

    private func requestExif(for asset: PHAsset) async -> [String: Any]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[String: Any]?, Never>) in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            var resumed = false
            asset.requestContentEditingInput(with: options) { input, _ in
                guard !resumed else { return }
                resumed = true
                guard let url = input?.fullSizeImageURL,
                      let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
                else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: props)
            }
        }
    }

    private func parseExif(_ props: [String: Any], into meta: inout PhotoMetadata) {
        if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            meta.cameraMake  = (tiff[kCGImagePropertyTIFFMake  as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            meta.cameraModel = (tiff[kCGImagePropertyTIFFModel as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            meta.lens = (exif[kCGImagePropertyExifLensModel as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let a = exif[kCGImagePropertyExifFNumber as String] as? Double {
                meta.aperture = a
            }
            if let s = exif[kCGImagePropertyExifExposureTime as String] as? Double {
                meta.shutterSpeed = formatShutter(s)
            }
            if let isos = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int],
               let first = isos.first {
                meta.iso = first
            }
            if let f = exif[kCGImagePropertyExifFocalLength as String] as? Double {
                meta.focalLength = f
            }
        }
    }

    private func formatShutter(_ seconds: Double) -> String {
        if seconds >= 1 { return String(format: "%.1fs", seconds) }
        let denom = max(1, Int((1.0 / seconds).rounded()))
        return "1/\(denom)s"
    }
}

// MARK: - Full-resolution image loader

struct FullSizePhotoView: View {
    let item: PhotoItem
    @ObservedObject var cache: LightboxImageCache
    @State private var image: PlatformImage?

    init(item: PhotoItem, cache: LightboxImageCache) {
        self.item = item
        self.cache = cache
        // Seed from the cache synchronously so a cached image renders on the very
        // first frame — no spinner flash between arrow presses.
        _image = State(initialValue: cache.cached(for: item))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
                    // Absorb taps that land on the image itself; the surrounding
                    // black area still dismisses via the backdrop's tap gesture.
                    .contentShape(Rectangle())
                    .onTapGesture { }
            } else {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) {
            if image != nil { return }
            image = await cache.load(item: item)
        }
    }
}
