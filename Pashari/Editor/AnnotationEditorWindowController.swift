import AppKit
import SwiftUI

/// One editor window: builds it, shows it, and handles Copy, Save and Close.
final class AnnotationEditorWindowController: NSObject, NSWindowDelegate {
    /// Called once when the window closes. The argument is the edited
    /// screenshot when it still needs a home (the window was simply closed),
    /// or nil when it was already copied or saved.
    var onClose: ((Screenshot?) -> Void)?

    let model: EditorModel
    let window: NSWindow
    let canvas: AnnotationCanvasView
    private let scrollView = NSScrollView()
    /// The SwiftUI toolbar, wrapped so it can live in an AppKit window.
    /// `lazy` because building it needs `self` for the button actions.
    private lazy var toolbar = NSHostingView(
        rootView: EditorToolbarView(
            model: model,
            onCopy: { [weak self] in self?.copyToClipboard() },
            onSave: { [weak self] in self?.saveToDisk() }
        )
    )
    /// True once Copy or Save has taken care of the result.
    private var isDelivered = false

    /// A starting point for the narrowest the window may be. The real limit
    /// is whatever the toolbar needs, which depends on the language and is
    /// measured once the toolbar exists (see `init`).
    private static let minimumContentWidth: CGFloat = 900
    private static let minimumCanvasHeight: CGFloat = 280
    /// Empty space left around the image.
    private static let canvasPadding: CGFloat = 24

    init(screenshot: Screenshot) {
        model = EditorModel(screenshot: screenshot)
        canvas = AnnotationCanvasView(model: model)
        window = NSWindow(
            contentRect: Self.initialContentRect(for: screenshot.pointSize),
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

        // Never let the window get narrower than its toolbar, and widen it
        // now if it already is.
        let toolbarWidth = ceil(toolbar.fittingSize.width)
        if toolbarWidth > window.contentMinSize.width {
            window.contentMinSize.width = toolbarWidth
        }
        if let contentSize = window.contentView?.frame.size, contentSize.width < toolbarWidth {
            window.setContentSize(CGSize(width: toolbarWidth, height: contentSize.height))
        }
        window.center()
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
        // Pinch to zoom, handled entirely by the scroll view.
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8

        // Auto Layout: instead of setting frames, state the rules ("the
        // toolbar is pinned to the top, the scroll view fills the rest") and
        // let AppKit work out the frames whenever the window is resized.
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

    /// Big enough to show the image at its real size where possible, but
    /// never larger than most of the screen.
    private static func initialContentRect(for imageSize: CGSize) -> CGRect {
        let screenSize = (NSScreen.underMouse ?? NSScreen.main)?.visibleFrame.size
            ?? CGSize(width: 1280, height: 800)
        return CGRect(
            origin: .zero,
            size: initialContentSize(for: imageSize, screenSize: screenSize)
        )
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

    // Edit > Copy (⌘C) and File > Save (⌘S) in the hidden main menu (see
    // MainMenu) end up here. The menu asks the view with keyboard focus
    // first, then the views around it, then the window, and then the
    // window's delegate, which is this object. So these work wherever the
    // focus is in the editor, except that ⌘C copies the selected text while
    // text is being typed. (Undo and Redo are handled by the canvas.)

    // `@objc(copy:)` is the name the menu asks for. The Swift name is
    // different because every NSObject already has a `copy()` method.
    @objc(copy:) func copyImage(_ sender: Any?) {
        copyToClipboard()
    }

    @objc func saveDocument(_ sender: Any?) {
        saveToDisk()
    }

    // MARK: - Actions

    // Not named `copy()`: every NSObject already has a method of that name.
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

    /// Bakes the annotations in, hands the result to `output`, and closes
    /// the window if that worked.
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
            // The window stays open, with the work in it.
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
        // Closing without Copy or Save does not throw the work away: the
        // result goes back to a floating thumbnail.
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
