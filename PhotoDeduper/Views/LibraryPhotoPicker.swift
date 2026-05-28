#if os(macOS)
import SwiftUI
import PhotosUI
import AppKit

/// Presents `PHPickerViewController` as a true macOS **window-modal sheet**
/// via `NSWindow.beginSheet(_:completionHandler:)`.
///
/// ## Why not SwiftUI's `.sheet()`?
/// SwiftUI's `.sheet()` on macOS renders a floating panel that does **not**
/// call `NSWindow.beginSheet`.  The parent window stays fully interactive,
/// so mouse clicks inside the picker's sidebar bleed through to SwiftUI
/// buttons sitting underneath it.  `NSWindow.beginSheet` properly blocks
/// all input to the parent window for the lifetime of the picker.
///
/// ## Usage
/// Drop this into your view hierarchy as a zero-size background/overlay,
/// then drive it with a `@Binding<Bool>`:
///
/// ```swift
/// .background(
///     LibraryPhotoPicker(
///         isPresented: $showPhotoPicker,
///         filter: .images
///     ) { results in … }
///     .frame(width: 0, height: 0)
/// )
/// ```
struct LibraryPhotoPicker: NSViewRepresentable {
    @Binding var isPresented: Bool
    var filter: PHPickerFilter
    var onFinish: ([PHPickerResult]) -> Void

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.pendingFilter  = filter
        coordinator.pendingOnFinish = onFinish

        if isPresented && !coordinator.isPresenting {
            // Defer one run-loop tick so the view is fully attached to its window.
            DispatchQueue.main.async { [weak view] in
                guard let window = view?.window else { return }
                coordinator.present(from: window)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        @Binding var isPresented: Bool

        /// Captured from the latest `updateNSView` call so the delegate
        /// closure always uses up-to-date values even if SwiftUI re-renders
        /// between presentation and dismissal.
        var pendingFilter:   PHPickerFilter     = .images
        var pendingOnFinish: ([PHPickerResult]) -> Void = { _ in }

        private(set) var isPresenting = false
        private weak var sheetPanel: NSPanel?

        init(isPresented: Binding<Bool>) {
            _isPresented = isPresented
        }

        // MARK: Present

        func present(from window: NSWindow) {
            guard !isPresenting else { return }
            isPresenting = true

            var config = PHPickerConfiguration(photoLibrary: PHPhotoLibrary.shared())
            config.selectionLimit = 0   // unlimited
            config.filter = pendingFilter

            let picker = PHPickerViewController(configuration: config)
            picker.delegate = self

            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                styleMask: [.titled, .resizable],
                backing:   .buffered,
                defer:     false
            )
            panel.contentViewController = picker
            // PHPickerViewController resets preferredContentSize during viewDidLoad
            // (triggered by the contentViewController assignment above). Set the
            // panel size explicitly afterwards so our dimensions win.
            panel.setContentSize(NSSize(width: 1100, height: 700))
            panel.title    = "Select Photos"
            panel.minSize  = NSSize(width: 700, height: 500)
            sheetPanel = panel

            // beginSheet blocks the parent window for the sheet's lifetime.
            window.beginSheet(panel) { [weak self] _ in
                self?.isPresenting = false
                self?.sheetPanel   = nil
            }
        }

        // MARK: PHPickerViewControllerDelegate

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let panel = sheetPanel else { return }
            panel.sheetParent?.endSheet(panel)
            // isPresenting / sheetPanel are cleared by the beginSheet completion above.
            isPresented = false
            pendingOnFinish(results)
        }
    }
}

#else
// MARK: - iOS implementation

import SwiftUI
import PhotosUI

/// On iOS, presents `PHPickerViewController` as a standard sheet.
/// The macOS version uses `NSWindow.beginSheet()` to achieve true window-modal
/// behaviour; on iOS the standard sheet presentation is correct.
struct LibraryPhotoPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var filter: PHPickerFilter
    var onFinish: ([PHPickerResult]) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        // This view controller is just a host; the picker itself is presented
        // as a child sheet once `isPresented` becomes true.
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard isPresented, !context.coordinator.isPresenting else { return }
        context.coordinator.present(from: uiViewController, filter: filter, onFinish: onFinish)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        @Binding var isPresented: Bool
        private(set) var isPresenting = false

        init(isPresented: Binding<Bool>) {
            _isPresented = isPresented
        }

        func present(from vc: UIViewController, filter: PHPickerFilter, onFinish: @escaping ([PHPickerResult]) -> Void) {
            guard !isPresenting else { return }
            isPresenting = true

            var config = PHPickerConfiguration(photoLibrary: .shared())
            config.selectionLimit = 0   // unlimited
            config.filter = filter

            let picker = PHPickerViewController(configuration: config)
            picker.delegate = self
            // Capture callback so the delegate can call it after dismissal.
            self.pendingOnFinish = onFinish

            vc.present(picker, animated: true)
        }

        private var pendingOnFinish: ([PHPickerResult]) -> Void = { _ in }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true) { [weak self] in
                guard let self else { return }
                self.isPresenting = false
                self.isPresented = false
                self.pendingOnFinish(results)
            }
        }
    }
}
#endif
