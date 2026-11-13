import AppKit
import Carbon.HIToolbox

/// The view is exactly as large as the visible part of the image, one view
/// unit per image point. Zooming is done by the scroll view around it.
final class AnnotationCanvasView: NSView, NSTextViewDelegate {
    private let model: EditorModel

    private var draft: Annotation?
    private var cropDraft: CGRect?
    private var dragStart: CGPoint?

    /// While the selected annotation is being dragged with the select tool:
    /// where the drag began, and how far it has gone. The document is only
    /// changed when the mouse is released, so a whole drag is one undo step.
    private var moveStart: CGPoint?
    private var moveOffset = CGSize.zero

    /// The view the user is typing into with the text tool, and where the
    /// text will go (in image points).
    private var textView: NSTextView?
    private var textOrigin: CGPoint?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: CGRect(origin: .zero, size: model.visibleRect.size))
        clipsToBounds = true
        model.onDocumentChange = { [weak self] in self?.documentDidChange() }
        model.onToolChange = { [weak self] in self?.toolDidChange() }
        model.onStyleChange = { [weak self] in self?.applyTextStyle() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AnnotationCanvasView is created in code only")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Keeping up with the model

    private func documentDidChange() {
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

        var annotations = model.document.annotations.map { annotation in
            annotation.id == model.selectedID ? annotation.translated(by: moveOffset) : annotation
        }
        if let draft {
            annotations.append(draft)
        }
        AnnotationRenderer.draw(
            annotations,
            over: model.screenshot,
            blurredImage: model.blurredImage(for: annotations),
            in: context
        )

        if let selected = annotations.first(where: { $0.id == model.selectedID }) {
            drawSelectionOutline(around: selected.bounds, in: context)
        }

        if let cropDraft {
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
        guard !model.isExporting else { return }
        if textView != nil {
            commitText()
            if model.tool == .text { return }
        }
        window?.makeFirstResponder(self)

        let point = imagePoint(of: event)
        switch model.tool {
        case .select:
            if model.select(at: point) {
                moveStart = point
            }
        case .text:
            beginText(at: point)
        case .counter:
            model.add(.counter(model.document.nextCounterNumber, center: point))
        case .pen:
            draft = makeDraft(.pen([point]))
        case .arrow, .line, .rectangle, .ellipse, .blur, .crop:
            dragStart = point
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(of: event)

        if case .pen(let points) = draft?.shape {
            draft?.shape = .pen(points + [point])
        } else if let moveStart {
            moveOffset = CGSize(width: point.x - moveStart.x, height: point.y - moveStart.y)
        } else if let dragStart {
            if model.tool == .crop {
                cropDraft = CGRect(corner: dragStart, oppositeCorner: point)
            } else {
                let end = event.modifierFlags.contains(.shift)
                    ? model.tool.constrainedEnd(from: dragStart, to: point, within: model.visibleRect)
                    : point
                if let shape = model.tool.shape(from: dragStart, to: end) {
                    draft = makeDraft(shape)
                }
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
        case .pen(let points):
            points.count >= 2
        case .text, .counter:
            true
        }
    }

    // MARK: - Keyboard

    // Edit > Undo and Redo in the hidden main menu (⌘Z, ⇧⌘Z; see MainMenu)
    // arrive here while the canvas, or the text being typed on it, has
    // keyboard focus. Further out, the window would take them, but the
    // window only knows how to undo typing.

    @objc func undo(_ sender: Any?) {
        if let typingUndo = textView?.undoManager {
            if typingUndo.canUndo { typingUndo.undo() }
        } else {
            model.undo()
        }
    }

    @objc func redo(_ sender: Any?) {
        if let typingUndo = textView?.undoManager {
            if typingUndo.canRedo { typingUndo.redo() }
        } else {
            model.redo()
        }
    }

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
        let visible = model.visibleRect

        let textView = NSTextView(
            frame: CGRect(origin: CGPoint(x: point.x - visible.minX, y: point.y - visible.minY), size: .zero)
        )
        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        // Type exactly what the user types: no curly quotes, no autocorrect.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false

        // No padding around the text, so the first character sits exactly
        // where the finished text will be drawn.
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0

        // Never wrap: lines break only where the user presses Return. The
        // text is laid out in an area of unlimited size, and the view itself
        // is resized to fit after every edit (see `fitTextViewToText`).
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false

        addSubview(textView)
        self.textView = textView
        textOrigin = point
        applyTextStyle()
        window?.makeFirstResponder(textView)
    }

    private func applyTextStyle() {
        guard let textView else { return }
        let attributes = AnnotationRenderer.textAttributes(color: model.color, size: model.size)
        let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: model.size.fontSize)
        let color = attributes[.foregroundColor] as? NSColor ?? .red

        textView.font = font
        textView.textColor = color
        textView.insertionPointColor = color
        textView.typingAttributes = attributes
        // At least one line tall, so the cursor shows before anything is
        // typed.
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        textView.minSize = CGSize(width: 4, height: lineHeight)
        fitTextViewToText()
    }

    func finishEditing() {
        commitText()
    }

    private func commitText() {
        guard let textView, let origin = textOrigin else { return }
        // Clear these first: removing the view ends its editing session,
        // which calls back into this method.
        self.textView = nil
        textOrigin = nil

        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        textView.removeFromSuperview()
        if !text.isEmpty {
            model.add(.text(text, origin: origin))
        }
        window?.makeFirstResponder(self)
    }

    func textDidChange(_ notification: Notification) {
        fitTextViewToText()
    }

    private func fitTextViewToText() {
        guard
            let textView,
            let layoutManager = textView.layoutManager,
            let container = textView.textContainer
        else {
            return
        }

        // Height: lay the text out now and ask how far down it reaches. The
        // "extra line fragment" is the empty line after a trailing Return,
        // where the cursor sits; it has no characters but still needs room.
        layoutManager.ensureLayout(for: container)
        let usedHeight = max(
            layoutManager.usedRect(for: container).maxY,
            layoutManager.extraLineFragmentUsedRect.maxY
        )

        // Width: the widest line, measured line by line. (The layout
        // manager's own answer is no use here: for text with line breaks it
        // reports the full width of the unlimited layout area.)
        let attributes: [NSAttributedString.Key: Any] = [.font: textView.font as Any]
        let widestLine = textView.string
            .components(separatedBy: .newlines)
            .map { ($0 as NSString).size(withAttributes: attributes).width }
            .max() ?? 0

        textView.setFrameSize(
            CGSize(
                // A little spare width so the cursor after the last
                // character is not cut off.
                width: max(ceil(widestLine) + 2, textView.minSize.width),
                height: max(ceil(usedHeight), textView.minSize.height)
            )
        )
    }

    func textDidEndEditing(_ notification: Notification) {
        commitText()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            commitText()
            return true
        }
        return false
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
