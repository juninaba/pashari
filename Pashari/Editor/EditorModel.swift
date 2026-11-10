import CoreGraphics
import Observation

/// The state of one editor window: the screenshot, what has been drawn on
/// it, and which tool, colour and size are selected.
///
/// `@Observable` makes SwiftUI views that read these properties redraw when
/// they change. The AppKit canvas is not SwiftUI, so it is told through
/// `onDocumentChange` and `onToolChange` instead.
@Observable
final class EditorModel {
    let screenshot: Screenshot

    var tool: EditorTool = .arrow {
        didSet { onToolChange?() }
    }
    var color: AnnotationColor = .red
    var size: StrokeSize = .medium

    private var history = History(AnnotationDocument())

    @ObservationIgnored var onDocumentChange: (() -> Void)?
    @ObservationIgnored var onToolChange: (() -> Void)?

    /// Made the first time the blur tool needs it, then reused.
    @ObservationIgnored private var cachedBlurredImage: CGImage?

    init(screenshot: Screenshot) {
        self.screenshot = screenshot
    }

    // MARK: - Document

    var document: AnnotationDocument { history.current }
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    /// The whole image, in image points.
    var imageBounds: CGRect {
        CGRect(origin: .zero, size: screenshot.pointSize)
    }

    /// The part of the image currently shown: the crop, or everything.
    var visibleRect: CGRect {
        document.cropRect ?? imageBounds
    }

    /// Adds a mark using the selected colour and size.
    func add(_ shape: Annotation.Shape) {
        var document = history.current
        document.annotations.append(Annotation(shape: shape, color: color, size: size))
        apply(document)
    }

    /// Crops to `rect` (in image points), within what is visible now.
    func crop(to rect: CGRect) {
        let clipped = rect.intersection(visibleRect)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return }
        var document = history.current
        document.cropRect = clipped
        apply(document)
    }

    func undo() {
        history.undo()
        onDocumentChange?()
    }

    func redo() {
        history.redo()
        onDocumentChange?()
    }

    private func apply(_ document: AnnotationDocument) {
        history.apply(document)
        onDocumentChange?()
    }

    // MARK: - Rendering

    var blurredImage: CGImage? {
        if cachedBlurredImage == nil {
            cachedBlurredImage = AnnotationRenderer.blurredImage(of: screenshot)
        }
        return cachedBlurredImage
    }

    /// The screenshot with everything baked in, ready to copy or save.
    /// Returns the untouched original when nothing was changed.
    func flattened() -> Screenshot {
        guard !document.isEmpty else { return screenshot }
        return AnnotationRenderer.flatten(screenshot, with: document, blurredImage: blurredImage)
            ?? screenshot
    }
}
