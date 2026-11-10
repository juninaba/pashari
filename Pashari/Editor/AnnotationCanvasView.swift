import AppKit
import Carbon.HIToolbox

/// The drawing surface of the editor: shows the screenshot with its
/// annotations and turns mouse input into new annotations.
///
/// The view is exactly as large as the visible part of the image, one view
/// unit per image point. Zooming is done by the scroll view around it.
final class AnnotationCanvasView: NSView, NSTextFieldDelegate {
    private let model: EditorModel

    /// The annotation being drawn right now, not yet part of the document.
    private var draft: Annotation?
    /// The crop rectangle being dragged out, in image points.
    private var cropDraft: CGRect?
    private var dragStart: CGPoint?

    /// While the selected annotation is being dragged with the select tool:
    /// where the drag began, and how far it has gone. The document is only
    /// changed when the mouse is released, so a whole drag is one undo step.
    private var moveStart: CGPoint?
    private var moveOffset = CGSize.zero

    /// The field the user is typing into with the text tool, and where the
    /// text will go (in image points).
    private var textField: NSTextField?
    private var textOrigin: CGPoint?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: CGRect(origin: .zero, size: model.visibleRect.size))
        clipsToBounds = true
        model.onDocumentChange = { [weak self] in self?.documentDidChange() }
        model.onToolChange = { [weak self] in self?.toolDidChange() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AnnotationCanvasView is created in code only")
    }

    // Top-left origin with y growing downwards, like the image.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Keeping up with the model

    private func documentDidChange() {
        // Cropping (and undoing a crop) changes how much is visible.
        setFrameSize(model.visibleRect.size)
        needsDisplay = true
    }

    private func toolDidChange() {
        commitText()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let visible = model.visibleRect

        context.saveGState()
        // From here on, coordinates are image points: the visible part's
        // top-left corner sits at the view's top-left corner.
        context.translateBy(x: -visible.minX, y: -visible.minY)
        // Since macOS 14 a view may draw outside its own bounds unless it
        // says otherwise. Without this, the cropped-away parts of the image
        // would spill out around the canvas.
        context.clip(to: visible)

        // What to draw: the document, with the annotation being dragged
        // shown at its new place and the one being drawn added on top.
        var annotations = model.document.annotations.map { annotation in
            annotation.id == model.selectedID ? annotation.translated(by: moveOffset) : annotation
        }
        if let draft {
            annotations.append(draft)
        }
        AnnotationRenderer.draw(
            annotations,
            over: model.screenshot,
            blurredImage: model.blurredImage,
            in: context
        )

        if let selected = annotations.first(where: { $0.id == model.selectedID }) {
            drawSelectionOutline(around: selected.bounds, in: context)
        }

        if let cropDraft {
            // Dim what would be cut away.
            context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            context.addRect(visible)
            context.addRect(cropDraft)
            context.fillPath(using: .evenOdd)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1)
            context.stroke(cropDraft)
        }
        context.restoreGState()
    }

    /// A dashed frame around the selected annotation. Drawn in white first
    /// and the accent colour on top, so it shows on any background.
    private func drawSelectionOutline(around bounds: CGRect, in context: CGContext) {
        let frame = bounds.insetBy(dx: -4, dy: -4)
        context.saveGState()
        context.setLineWidth(1.5)
        context.setStrokeColor(NSColor.white.cgColor)
        context.stroke(frame)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineDash(phase: 0, lengths: [5, 4])
        context.stroke(frame)
        context.restoreGState()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        // A click anywhere finishes text that was being typed.
        if textField != nil {
            commitText()
            if model.tool == .text { return }
        }
        window?.makeFirstResponder(self)

        let point = imagePoint(of: event)
        switch model.tool {
        case .select:
            // Clicking a mark selects it and readies it for dragging;
            // clicking empty space clears the selection.
            if model.select(at: point) {
                moveStart = point
            }
        case .text:
            beginText(at: point)
        case .counter:
            model.add(.counter(model.document.nextCounterNumber, center: point))
        case .pen:
            draft = makeDraft(.pen([point]))
        case .highlighter:
            draft = makeDraft(.highlighter([point]))
        case .arrow, .line, .rectangle, .ellipse, .blur, .crop:
            dragStart = point
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(of: event)

        if case .pen(let points) = draft?.shape {
            draft?.shape = .pen(points + [point])
        } else if case .highlighter(let points) = draft?.shape {
            draft?.shape = .highlighter(points + [point])
        } else if let moveStart {
            moveOffset = CGSize(width: point.x - moveStart.x, height: point.y - moveStart.y)
        } else if let dragStart {
            if model.tool == .crop {
                cropDraft = CGRect(corner: dragStart, oppositeCorner: point)
            } else if let shape = model.tool.shape(from: dragStart, to: point) {
                draft = makeDraft(shape)
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            draft = nil
            cropDraft = nil
            dragStart = nil
            moveStart = nil
            moveOffset = .zero
            needsDisplay = true
        }

        if moveStart != nil {
            model.moveSelected(by: moveOffset)
        } else if let cropDraft {
            // Ignore a crop too small to be meant.
            if cropDraft.width >= 8, cropDraft.height >= 8 {
                model.crop(to: cropDraft)
            }
        } else if let draft, Self.isLargeEnough(draft.shape) {
            model.add(draft.shape)
        }
    }

    private func makeDraft(_ shape: Annotation.Shape) -> Annotation {
        Annotation(shape: shape, color: model.color, size: model.size)
    }

    /// The event's position in image points, kept inside the visible part.
    private func imagePoint(of event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let visible = model.visibleRect
        return CGPoint(
            x: min(max(point.x, 0), visible.width) + visible.minX,
            y: min(max(point.y, 0), visible.height) + visible.minY
        )
    }

    /// Whether a finished drag is big enough to keep. A click that barely
    /// moved would otherwise leave an invisible speck behind.
    static func isLargeEnough(_ shape: Annotation.Shape) -> Bool {
        switch shape {
        case .arrow(let from, let to), .line(let from, let to):
            hypot(to.x - from.x, to.y - from.y) >= 3
        case .rectangle(let rect), .ellipse(let rect), .blur(let rect):
            rect.width >= 3 && rect.height >= 3
        case .pen(let points), .highlighter(let points):
            points.count >= 2
        case .text, .counter:
            true
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Delete, kVK_ForwardDelete:
            model.deleteSelected()
        case kVK_Escape:
            model.deselect()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Text tool

    private func beginText(at point: CGPoint) {
        let attributes = AnnotationRenderer.textAttributes(color: model.color, size: model.size)
        let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: model.size.fontSize)
        let visible = model.visibleRect

        let field = NSTextField(frame: .zero)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = attributes[.foregroundColor] as? NSColor
        field.delegate = self
        field.cell?.isScrollable = true

        // A text field keeps a small gap before its first character. Shift
        // it left by that gap so the typed text sits where the final text
        // will be drawn.
        let textInset: CGFloat = 2
        let x = point.x - visible.minX - textInset
        let y = point.y - visible.minY
        field.frame = CGRect(
            x: x,
            y: y,
            width: max(bounds.maxX - x, 120),
            height: ceil(font.ascender - font.descender + font.leading) + 2
        )

        addSubview(field)
        window?.makeFirstResponder(field)

        // While a text field is being edited, the typing is actually done by
        // a shared helper view called the field editor, laid over the field.
        // Make it see-through and coloured like the final text, so typing
        // looks the same as the result.
        if let editor = field.currentEditor() as? NSTextView {
            editor.drawsBackground = false
            editor.insertionPointColor = field.textColor ?? .textColor
        }

        textField = field
        textOrigin = point
    }

    /// Finishes whatever is half done, so the document is complete before it
    /// is exported.
    func finishEditing() {
        commitText()
    }

    /// Turns what was typed into an annotation and removes the field.
    private func commitText() {
        guard let field = textField, let origin = textOrigin else { return }
        // Clear these first: removing the field ends its editing session,
        // which calls back into this method.
        textField = nil
        textOrigin = nil

        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        if !text.isEmpty {
            model.add(.text(text, origin: origin))
        }
        window?.makeFirstResponder(self)
    }

    // NSTextFieldDelegate: Return, Tab or a click elsewhere ended editing.
    func controlTextDidEndEditing(_ notification: Notification) {
        commitText()
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        let cursor: NSCursor = switch model.tool {
        case .select: .arrow
        case .text: .iBeam
        default: .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }
}
