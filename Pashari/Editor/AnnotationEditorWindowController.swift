import AppKit
import SwiftUI

/// One editor window: builds it, shows it, and handles Copy, Save and Close.
final class AnnotationEditorWindowController: NSObject, NSWindowDelegate {
    /// Called once when the window closes. The argument is the edited
    /// screenshot when it still needs a home (the window was simply closed),
    /// or nil when it was already copied or saved.
    var onClose: ((Screenshot?) -> Void)?

    let model: EditorModel
    let window: EditorWindow
    private let canvas: AnnotationCanvasView
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
        window = EditorWindow(
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
        window.onKeyCommand = { [weak self] command in self?.perform(command) }
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

    // MARK: - Actions

    private func perform(_ command: EditorKeyCommand) {
        switch command {
        case .undo: model.undo()
        case .redo: model.redo()
        case .copy: copyToClipboard()
        case .save: saveToDisk()
        case .close: window.performClose(nil)
        }
    }

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
        canvas.finishEditing()
        let screenshot = model.flattened()
        Task {
            do {
                try await output(screenshot)
                isDelivered = true
                window.close()
            } catch {
                ErrorAlert.show(error, title: errorTitle)
            }
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        canvas.finishEditing()
        // Closing without Copy or Save does not throw the work away: the
        // result goes back to a floating thumbnail.
        onClose?(isDelivered ? nil : model.flattened())
        onClose = nil
    }
}
