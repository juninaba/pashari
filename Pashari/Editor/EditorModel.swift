import CoreGraphics
import Foundation
import Observation

/// The state of one editor window: the screenshot, what has been drawn on
/// it, and which tool, colour and size are selected.
///
/// `@Observable` makes SwiftUI views that read these properties redraw when
/// they change. The AppKit canvas is not SwiftUI, so it is told through
/// `onDocumentChange` (the document or the selection changed),
/// `onToolChange` and `onStyleChange` instead.
@Observable
final class EditorModel {
    let screenshot: Screenshot

    var tool: EditorTool = .arrow {
        didSet {
            // A selection only means something to the select tool.
            if tool != .select {
                deselect()
            }
            onToolChange?()
        }
    }
    var color: AnnotationColor = .red {
        didSet { onStyleChange?() }
    }
    var size: StrokeSize = .medium {
        didSet { onStyleChange?() }
    }

    private var history = History(AnnotationDocument())

    /// The mark picked with the select tool. Not part of the undo history:
    /// selecting something is not a change to the picture.
    private(set) var selectedID: UUID?

    @ObservationIgnored var onDocumentChange: (() -> Void)?
    @ObservationIgnored var onToolChange: (() -> Void)?
    /// The colour or the size changed.
    @ObservationIgnored var onStyleChange: (() -> Void)?

    /// See `blurredImage(for:)`. `lazy` means it is worked out on first use.
    /// A lazy property runs its initial value only once, even when that
    /// gives nil, so a blur that fails is not tried again at every redraw.
    @ObservationIgnored private lazy var cachedBlurredImage = AnnotationRenderer.blurredImage(
        of: screenshot
    )

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
    ///
    /// Each edge first moves to the nearest whole pixel. In a zoomed editor
    /// the mouse lands between pixels, and an image cut there would have to
    /// be resampled to be saved, which blurs it.
    func crop(to rect: CGRect) {
        let clipped = rect.snappedToPixels(scale: screenshot.scale).intersection(visibleRect)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return }
        var document = history.current
        document.cropRect = clipped
        apply(document)
    }

    func undo() {
        history.undo()
        dropStaleSelection()
        onDocumentChange?()
    }

    func redo() {
        history.redo()
        dropStaleSelection()
        onDocumentChange?()
    }

    // MARK: - Selection

    var selectedAnnotation: Annotation? {
        document.annotations.first { $0.id == selectedID }
    }

    /// Selects the topmost mark at `point` (in image points), or clears the
    /// selection when there is none. Returns whether something was hit.
    @discardableResult
    func select(at point: CGPoint) -> Bool {
        setSelection(document.topmostAnnotation(at: point)?.id)
        return selectedID != nil
    }

    func deselect() {
        setSelection(nil)
    }

    /// Moves the selected mark. One call is one undo step.
    func moveSelected(by offset: CGSize) {
        guard offset != .zero else { return }
        var document = history.current
        guard let index = document.annotations.firstIndex(where: { $0.id == selectedID }) else {
            return
        }
        document.annotations[index] = document.annotations[index].translated(by: offset)
        apply(document)
    }

    func deleteSelected() {
        guard selectedID != nil else { return }
        var document = history.current
        document.annotations.removeAll { $0.id == selectedID }
        selectedID = nil
        apply(document)
    }

    private func setSelection(_ id: UUID?) {
        guard id != selectedID else { return }
        selectedID = id
        onDocumentChange?()
    }

    /// After undo or redo the selected mark may no longer exist.
    private func dropStaleSelection() {
        if selectedAnnotation == nil {
            selectedID = nil
        }
    }

    private func apply(_ document: AnnotationDocument) {
        history.apply(document)
        onDocumentChange?()
    }

    // MARK: - Rendering

    /// The blurred copy of the screenshot that blur marks show, or nil when
    /// `annotations` holds no blur mark. Blurring a whole Retina screenshot
    /// takes a moment, and as much memory again as the screenshot, so it is
    /// done only once a blur mark needs it, and then kept.
    func blurredImage(for annotations: [Annotation]) -> CGImage? {
        annotations.contains(where: \.isBlur) ? cachedBlurredImage : nil
    }

    /// The screenshot with everything baked in, ready to copy or save.
    /// Returns the untouched original when nothing was changed.
    func flattened() throws -> Screenshot {
        guard !document.isEmpty else { return screenshot }
        return try AnnotationRenderer.flatten(
            screenshot,
            with: document,
            blurredImage: blurredImage(for: document.annotations)
        )
    }
}
