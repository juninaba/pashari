import AppKit
import SwiftUI

final class AnnotationEditorWindowController: NSObject, NSWindowDelegate {
    /// Called once when the window closes. The argument is the edited
    /// screenshot when it still needs a home (the window was simply closed),
    /// or nil when it was pinned, copied, saved or discarded.
    var onClose: ((Screenshot?) -> Void)?
    var onPin: ((Screenshot) async throws -> Void)?

    let model: EditorModel
    let window: Window
    let canvas: AnnotationCanvasView
    private let printView: EditorPrintView
    private let showError: @MainActor (Error, String) -> Void
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
            onPin: { [weak self] in self?.pinToScreen() },
            onCopy: { [weak self] in self?.copyToClipboard() },
            onSave: { [weak self] in self?.saveToDisk() }
        )
    )
    private var thumbnailResult: Screenshot?

    /// A starting point for the narrowest the window may be. The real limit
    /// is whatever the toolbar needs, which depends on the language and is
    /// measured once the toolbar exists (see `init`).
    private static let minimumContentWidth: CGFloat = 900
    private static let minimumCanvasHeight: CGFloat = 280
    private static let canvasPadding: CGFloat = 24

    convenience init(screenshot: Screenshot) {
        self.init(model: EditorModel(screenshot: screenshot))
    }

    init(model: EditorModel, showError: @escaping @MainActor (Error, String) -> Void = ErrorAlert.show(_:title:)) {
        self.model = model
        self.showError = showError
        canvas = AnnotationCanvasView(model: model)
        printView = EditorPrintView(canvas: canvas)
        let screen = NSScreen.underMouse ?? NSScreen.main
        window = Window(
            contentRect: CGRect(
                origin: .zero,
                size: Self.initialContentSize(
                    for: model.screenshot.pointSize,
                    screenSize: screen?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
                )
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = String(localized: "Annotate Screenshot")
        // The title bar takes the toolbar's colour, so that the two read as
        // one. The title still names the window in the Window menu and in
        // Mission Control.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = EditorStyle.header
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
    ///
    /// A picture far taller than the window, such as a scroll capture, would
    /// shrink to a thin strip to fit whole. It is fitted to the window's
    /// width instead, and shown from its top, to be scrolled through.
    func zoomToFit() {
        // Make sure the window has worked out its layout, so the scroll
        // view's size is the real one.
        window.layoutIfNeeded()
        let available = scrollView.contentSize
        let padded = printView.frame.insetBy(dx: -Self.canvasPadding, dy: -Self.canvasPadding)
        let fittingWidth = min(available.width / padded.width, 1)
        let fittingWhole = min(fittingWidth, available.height / padded.height)
        guard fittingWhole < 1 else { return }

        if fittingWhole < fittingWidth / 2 {
            scrollView.magnification = fittingWidth
            printView.scroll(.zero)
        } else {
            scrollView.magnify(toFit: padded)
        }
    }

    // MARK: - Building the window

    private func makeContentView() -> NSView {
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = printView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        // The desk behind it shows through.
        scrollView.drawsBackground = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8

        let desk = EditorDeskView()
        let separator = NSBox()
        separator.boxType = .separator

        let container = NSView()
        for view in [desk, scrollView, toolbar, separator] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: EditorToolbarView.height),

            separator.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            desk.topAnchor.constraint(equalTo: scrollView.topAnchor),
            desk.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            desk.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            desk.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ])
        return container
    }

    static func initialContentSize(for imageSize: CGSize, screenSize: CGSize) -> CGSize {
        let maximum = CGSize(width: screenSize.width * 0.85, height: screenSize.height * 0.85)
        let margin = (canvasPadding + EditorPrintView.border) * 2
        let wanted = CGSize(
            width: imageSize.width + margin,
            height: imageSize.height + margin + EditorToolbarView.height
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

    @discardableResult
    func pinToScreen() -> Task<Void, Never>? {
        guard let onPin else { return nil }
        return deliver(errorTitle: String(localized: "The screenshot could not be pinned"), to: onPin)
    }

    private func copyToClipboard() {
        deliver(errorTitle: String(localized: "The screenshot could not be copied")) { screenshot in
            let png = try await ScreenshotWriter.pngData(for: screenshot)
            try Clipboard.copy(pngData: png)
        }
    }

    private func saveToDisk() {
        deliver(errorTitle: String(localized: "The screenshot could not be saved")) { screenshot in
            _ = try await ScreenshotWriter.save(screenshot, in: Preferences.saveDirectory())
        }
    }

    @discardableResult
    private func deliver(
        errorTitle: String,
        to output: @escaping (Screenshot) async throws -> Void
    ) -> Task<Void, Never>? {
        // Encoding a large screenshot takes a moment. A second click on Save
        // (or a held-down ⌘S) in that time would save it twice.
        guard !model.isExporting, window.attachedSheet == nil else { return nil }
        canvas.finishEditing()
        let screenshot: Screenshot
        do {
            screenshot = try model.flattened()
        } catch {
            showError(error, errorTitle)
            return nil
        }

        model.isExporting = true
        return Task {
            do {
                try await output(screenshot)
                window.closeNow()
            } catch {
                model.isExporting = false
                showError(error, errorTitle)
            }
        }
    }

    // MARK: - Closing

    private func requestClose() {
        guard !model.isExporting, window.attachedSheet == nil else { return }
        canvas.finishEditing()
        do {
            thumbnailResult = try model.flattened()
            window.closeNow()
        } catch {
            showCloseError(error)
        }
    }

    private func showCloseError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "The screenshot could not be returned to the thumbnail")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "Keep Editing"))
        alert.addButton(withTitle: String(localized: "Discard Screenshot")).hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn {
                self?.window.closeNow()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        window.delegate = nil
        let result = thumbnailResult
        thumbnailResult = nil
        let notify = onClose
        onClose = nil
        notify?(result)
    }

    final class Window: NSWindow {
        // The close button and ⌘W reach close() through performClose(_:).
        // Direct calls to close() bypass the windowShouldClose delegate hook.
        override func close() {
            if let editor = delegate as? AnnotationEditorWindowController {
                editor.requestClose()
            } else {
                super.close()
            }
        }

        fileprivate func closeNow() {
            super.close()
        }
    }
}
