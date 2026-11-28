import CoreGraphics
import Foundation
import Observation

/// `@Observable` makes SwiftUI views that read these properties redraw when
/// they change. The AppKit canvas is not SwiftUI, so it is told through
/// `onDocumentChange` (the document or the selection changed),
/// `onToolChange` and `onStyleChange` instead.
@Observable
final class EditorModel {
    let screenshot: Screenshot
    private let renderBlur: @MainActor (Screenshot) -> CGImage?

    var tool: EditorTool = .arrow {
        didSet {
            if tool != .select {
                deselect()
            }
            onToolChange?()
        }
    }
    var color: AnnotationColor = .red {
        didSet {
            if editingText != nil, editingText?.color != color {
                editingText?.color = color
            }
            onStyleChange?()
        }
    }
    var size: StrokeSize = .medium {
        didSet {
            if editingText != nil, editingText?.size != size {
                editingText?.size = size
            }
            onStyleChange?()
        }
    }

    /// True while Pin, Copy or Save turns the picture into a PNG. The picture
    /// cannot change meanwhile: a change would be missing from the result,
    /// and lost when the window closes after it.
    var isExporting = false

    private var history = History(AnnotationDocument())

    /// The mark picked with the select tool. Not part of the undo history:
    /// selecting something is not a change to the picture.
    private(set) var selectedID: UUID?

    private struct TextEditingState: Equatable {
        let id: UUID
        var color: AnnotationColor
        var size: StrokeSize
    }

    /// An existing text mark currently open for inline re-editing, with its
    /// uncommitted style so toolbar changes take effect live and commit in one
    /// undo step together with the text.
    private var editingText: TextEditingState?

    var editingTextID: UUID? { editingText?.id }

    /// The colour and size shown as active in the toolbar: the mark being
    /// edited or selected (nil when it has no colour or size, such as a blur),
    /// or the default style for new marks.
    var displayedColor: AnnotationColor? {
        if let editingText { return editingText.color }
        if let selected = selectedAnnotation {
            return selected.supportsStyle ? selected.color : nil
        }
        return color
    }

    var displayedSize: StrokeSize? {
        if let editingText { return editingText.size }
        if let selected = selectedAnnotation {
            return selected.supportsStyle ? selected.size : nil
        }
        return size
    }

    var canEditStyle: Bool {
        if editingText != nil { return true }
        return selectedAnnotation?.supportsStyle ?? true
    }

    private struct TypingUndoState: Equatable {
        var canUndo: Bool
        var canRedo: Bool
    }

    /// While an inline text view is open, toolbar Undo/Redo reflect its
    /// typing stack rather than the document history underneath.
    private var typingUndo: TypingUndoState?

    @ObservationIgnored var onDocumentChange: (() -> Void)?
    @ObservationIgnored var onToolChange: (() -> Void)?
    @ObservationIgnored var onStyleChange: (() -> Void)?

    @ObservationIgnored private var hasAttemptedBlur = false
    @ObservationIgnored private var cachedBlurredImage: CGImage?

    init(
        screenshot: Screenshot,
        renderBlur: @escaping @MainActor (Screenshot) -> CGImage? = AnnotationRenderer.blurredImage(of:)
    ) {
        self.screenshot = screenshot
        self.renderBlur = renderBlur
    }

    // MARK: - Document

    var document: AnnotationDocument { history.current }
    var canUndo: Bool { typingUndo?.canUndo ?? history.canUndo }
    var canRedo: Bool { typingUndo?.canRedo ?? history.canRedo }

    func setTypingUndoState(canUndo: Bool, canRedo: Bool) {
        let next = TypingUndoState(canUndo: canUndo, canRedo: canRedo)
        if typingUndo != next {
            typingUndo = next
        }
    }

    func clearTypingUndoState() {
        typingUndo = nil
    }

    var imageBounds: CGRect {
        CGRect(origin: .zero, size: screenshot.pointSize)
    }

    var visibleRect: CGRect {
        document.cropRect ?? imageBounds
    }

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
        guard !isExporting else { return }
        history.undo()
        dropStaleSelection()
        onDocumentChange?()
    }

    func redo() {
        guard !isExporting else { return }
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

    /// Applies a colour picked from the toolbar: restyles the selected mark
    /// (when it has a colour) or the text being edited, and becomes the
    /// default for new marks.
    func chooseColor(_ newColor: AnnotationColor) {
        guard !isExporting else { return }
        if editingText != nil {
            color = newColor
            return
        }
        if let selected = selectedAnnotation {
            guard selected.supportsStyle else { return }
            updateSelected { $0.color = newColor }
        }
        color = newColor
    }

    /// Applies a size picked from the toolbar: restyles the selected mark
    /// (when it has a size) or the text being edited, and becomes the default
    /// for new marks.
    func chooseSize(_ newSize: StrokeSize) {
        guard !isExporting else { return }
        if editingText != nil {
            size = newSize
            return
        }
        if let selected = selectedAnnotation {
            guard selected.supportsStyle else { return }
            updateSelected { $0.size = newSize }
        }
        size = newSize
    }

    /// Moves the selected mark. One call is one undo step.
    func moveSelected(by offset: CGSize) {
        guard offset != .zero else { return }
        updateSelected { $0 = $0.translated(by: offset) }
    }

    /// Replaces the selected mark's shape (for example after a handle drag).
    /// One call is one undo step.
    func updateSelectedShape(_ shape: Annotation.Shape) {
        updateSelected { $0.shape = shape }
    }

    func deleteSelected() {
        guard selectedID != nil else { return }
        var document = history.current
        document.annotations.removeAll { $0.id == selectedID }
        selectedID = nil
        apply(document)
    }

    func beginEditingText(id: UUID) {
        guard !isExporting,
              let annotation = document.annotations.first(where: { $0.id == id }),
              case .text = annotation.shape
        else {
            return
        }
        selectedID = id
        editingText = TextEditingState(id: id, color: annotation.color, size: annotation.size)
        onDocumentChange?()
    }

    /// Commits an inline edit to an existing text mark. Empty text removes
    /// the mark. One call is at most one undo step.
    func finishEditingText(id: UUID, text: String) {
        let style = editingText?.id == id ? editingText : nil
        editingText = nil

        var document = history.current
        guard !isExporting,
              let index = document.annotations.firstIndex(where: { $0.id == id })
        else {
            onDocumentChange?()
            return
        }

        if text.isEmpty {
            document.annotations.remove(at: index)
            if selectedID == id {
                selectedID = nil
            }
            apply(document)
        } else if case .text(_, let origin) = document.annotations[index].shape {
            document.annotations[index].shape = .text(text, origin: origin)
            if let style {
                document.annotations[index].color = style.color
                document.annotations[index].size = style.size
            }
            apply(document)
        } else {
            onDocumentChange?()
        }
    }

    private func updateSelected(_ mutate: (inout Annotation) -> Void) {
        guard let selectedID else { return }
        var document = history.current
        guard let index = document.annotations.firstIndex(where: { $0.id == selectedID }) else {
            return
        }
        mutate(&document.annotations[index])
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
        if let id = editingText?.id, !document.annotations.contains(where: { $0.id == id }) {
            editingText = nil
        }
    }

    private func apply(_ document: AnnotationDocument) {
        guard !isExporting else { return }
        history.apply(document)
        onDocumentChange?()
    }

    // MARK: - Rendering

    /// Generates the blurred copy when a blur mark first needs it. The
    /// canvas remembers a failure across redraws. Flattening can retry it.
    func blurredImage(for annotations: [Annotation], retryOnFailure: Bool = false) -> CGImage? {
        guard annotations.contains(where: \.isBlur) else { return nil }
        if !hasAttemptedBlur || (retryOnFailure && cachedBlurredImage == nil) {
            hasAttemptedBlur = true
            cachedBlurredImage = renderBlur(screenshot)
        }
        return cachedBlurredImage
    }

    /// The screenshot with everything baked in, ready to pin, copy or save.
    /// Returns the untouched original when nothing was changed.
    func flattened() throws -> Screenshot {
        guard !document.isEmpty else { return screenshot }
        return try AnnotationRenderer.flatten(
            screenshot,
            with: document,
            blurredImage: blurredImage(for: document.annotations, retryOnFailure: true)
        )
    }
}
