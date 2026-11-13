import AppKit
import SwiftUI

final class AnnotationEditorWindowController: NSObject, NSWindowDelegate {
    /// Called once when the window closes. The argument is the edited
    /// screenshot when it still needs a home (the window was simply closed),
    /// or nil when it was already copied or saved.
    var onClose: ((Screenshot?) -> Void)?

    let model: EditorModel
    let window: NSWindow
    let canvas: AnnotationCanvasView
    private let scrollView = NSScrollView()
    private lazy var toolbar = NSHostingView(
        rootView: EditorToolbarView(
            model: model,
            // The same as ⌘Z and ⇧⌘Z. While text is being typed, they take
            // back the typing; going past it to the picture underneath would
            // leave the text field over the wrong spot, say after a crop is
            // undone. (Clicking a toolbar button does not end the typing.)
            onUndo: { [weak self] in self?.canvas.undo(nil) },
            onRedo: { [weak self] in self?.canvas.redo(nil) },
            onCopy: { [weak self] in self?.copyToClipboard() },
            onSave: { [weak self] in self?.saveToDisk() }
        )
    )
    private var isDelivered = false

    /// A starting point for the narrowest the window may be. The real limit
    /// is whatever the toolbar needs, which depends on the language and is
    /// measured once the toolbar exists (see `init`).
    private static let minimumContentWidth: CGFloat = 900
    private static let minimumCanvasHeight: CGFloat = 280
    private static let canvasPadding: CGFloat = 24

    init(screenshot: Screenshot) {
        model = EditorModel(screenshot: screenshot)
        canvas = AnnotationCanvasView(model: model)
        let screen = NSScreen.underMouse ?? NSScreen.main
        window = NSWindow(
            contentRect: CGRect(
                origin: .zero,
                size: Self.initialContentSize(
                    for: screenshot.pointSize,
                    screenSize: screen?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
                )
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = String(localized: "Annotate Screenshot")
        window.isReleasedWhenClosed = false
        window.contentMinSize = CGSize(
            width: Self.minimumContentWidth,
            height: Self.minimumCanvasHeight + EditorToolbarView.height
        )
        window.delegate = self
        window.contentView = makeContentView()

        let toolbarWidth = ceil(toolbar.fittingSize.width)
        if toolbarWidth > window.contentMinSize.width {
            window.contentMinSize.width = toolbarWidth
        }
        if let contentSize = window.contentView?.frame.size, contentSize.width < toolbarWidth {
            window.setContentSize(CGSize(width: toolbarWidth, height: contentSize.height))
        }
        if let screen {
            window.center(on: screen)
        } else {
            window.center()
        }
    }

    func show() {
        // A menu bar app is not the active app, so its window would open
        // behind everything else without this.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        zoomToFit()
    }

    /// Zooms out when the image does not fit in the window. Smaller images
    /// are shown at their real size.
    func zoomToFit() {
        // Make sure the window has worked out its layout, so the scroll
        // view's size is the real one.
        window.layoutIfNeeded()
        let available = scrollView.contentSize
        let padded = canvas.frame.insetBy(dx: -Self.canvasPadding, dy: -Self.canvasPadding)
        if padded.width > available.width || padded.height > available.height {
            scrollView.magnify(toFit: padded)
        }
    }

    // MARK: - Building the window

    private func makeContentView() -> NSView {
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8

        let container = NSView()
        for view in [toolbar, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: EditorToolbarView.height),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    static func initialContentSize(for imageSize: CGSize, screenSize: CGSize) -> CGSize {
        let maximum = CGSize(width: screenSize.width * 0.85, height: screenSize.height * 0.85)
        let wanted = CGSize(
            width: imageSize.width + canvasPadding * 2,
            height: imageSize.height + canvasPadding * 2 + EditorToolbarView.height
        )
        let minimumHeight = minimumCanvasHeight + EditorToolbarView.height
        return CGSize(
            width: max(min(wanted.width, maximum.width), minimumContentWidth),
            height: max(min(wanted.height, maximum.height), minimumHeight)
        )
    }

    // MARK: - Menu shortcuts

    // `@objc(copy:)` is the name the menu asks for. The Swift name is
    // different because every NSObject already has a `copy()` method.
    @objc(copy:) func copyImage(_ sender: Any?) {
        copyToClipboard()
    }

    @objc func saveDocument(_ sender: Any?) {
        saveToDisk()
    }

    // MARK: - Actions

    private func copyToClipboard() {
        deliver(errorTitle: String(localized: "The screenshot could not be copied")) { screenshot in
            Clipboard.copy(pngData: try await ScreenshotWriter.pngData(for: screenshot))
        }
    }

    private func saveToDisk() {
        deliver(errorTitle: String(localized: "The screenshot could not be saved")) { screenshot in
            _ = try await ScreenshotWriter.save(screenshot, in: Preferences.saveDirectory())
        }
    }

    private func deliver(
        errorTitle: String,
        to output: @escaping (Screenshot) async throws -> Void
    ) {
        // Encoding a large screenshot takes a moment. A second click on Save
        // (or a held-down ⌘S) in that time would save it twice.
        guard !model.isExporting else { return }
        canvas.finishEditing()
        let screenshot: Screenshot
        do {
            screenshot = try model.flattened()
        } catch {
            ErrorAlert.show(error, title: errorTitle)
            return
        }

        model.isExporting = true
        Task {
            do {
                try await output(screenshot)
                isDelivered = true
                window.close()
            } catch {
                model.isExporting = false
                ErrorAlert.show(error, title: errorTitle)
            }
        }
    }

    // MARK: - NSWindowDelegate

    /// Asked when the user closes the window. While Copy or Save is still
    /// running the answer is no: the window closes itself once that is done,
    /// and closing it earlier would also hand the picture back as a
    /// thumbnail.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !model.isExporting
    }

    func windowWillClose(_ notification: Notification) {
        canvas.finishEditing()
        onClose?(isDelivered ? nil : resultForThumbnail())
        onClose = nil
    }

    /// The edited screenshot, or the original if the changes cannot be
    /// applied. Then the user is told, since the thumbnail would otherwise
    /// look like the finished work at a glance.
    private func resultForThumbnail() -> Screenshot {
        do {
            return try model.flattened()
        } catch {
            // After the window has finished closing, not in the middle of it.
            DispatchQueue.main.async {
                ErrorAlert.show(
                    error,
                    title: String(localized: "The thumbnail holds the screenshot without your changes")
                )
            }
            return model.screenshot
        }
    }
}
