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

    /// While one of the selected annotation's resize handles is being dragged.
    private struct ResizeDrag {
        let original: Annotation
        let handle: Annotation.Handle
        let handleOrigin: CGPoint
        let pressPoint: CGPoint
        var lastPoint: CGPoint
        var didDrag = false
        var current: Annotation
    }
    private var activeResize: ResizeDrag?

    /// The view the user is typing into with the text tool (or while
    /// re-editing an existing text mark), and where the text will go (in
    /// image points).
    private var textView: NSTextView?
    private var textOrigin: CGPoint?
    private weak var observedUndoManager: UndoManager?

    private weak var observedClipView: NSClipView?
    private var lastZoomScale: CGFloat = 1

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

    private var zoomScale: CGFloat {
        max(enclosingScrollView?.magnification ?? 1, 0.01)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeZoomChanges()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeZoomChanges()
    }

    // MARK: - Keeping up with the model

    private func documentDidChange() {
        setFrameSize(model.visibleRect.size)
        needsDisplay = true
        updateCursorForCurrentPointer()
    }

    private func toolDidChange() {
        commitText()
        updateCursorForCurrentPointer()
    }

    private func observeZoomChanges() {
        let clipView = enclosingScrollView?.contentView
        guard clipView !== observedClipView else { return }
        if let observedClipView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: observedClipView
            )
        }
        observedClipView = clipView
        lastZoomScale = zoomScale
        if let clipView {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipViewBoundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        let scale = zoomScale
        guard scale != lastZoomScale else { return }
        lastZoomScale = scale
        needsDisplay = true
        updateCursorForCurrentPointer()
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

        var annotations: [Annotation] = []
        annotations.reserveCapacity(model.document.annotations.count + (draft == nil ? 0 : 1))
        for annotation in model.document.annotations {
            if annotation.id == model.editingTextID {
                continue
            }
            if let activeResize, annotation.id == activeResize.original.id {
                annotations.append(activeResize.current)
            } else if annotation.id == model.selectedID, moveOffset != .zero {
                annotations.append(annotation.translated(by: moveOffset))
            } else {
                annotations.append(annotation)
            }
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

        if model.editingTextID == nil,
           let selected = annotations.first(where: { $0.id == model.selectedID })
        {
            drawSelection(for: selected, in: context)
        }

        if let cropDraft {
            context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            context.addRect(visible)
            context.addRect(cropDraft)
            context.fillPath(using: .evenOdd)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1 / zoomScale)
            context.stroke(cropDraft)
        }
        context.restoreGState()
    }

    private func drawSelection(for annotation: Annotation, in context: CGContext) {
        let scale = zoomScale
        switch annotation.shape {
        case .rectangle(let rect), .ellipse(let rect), .blur(let rect):
            drawSelectionOutline(frame: rect, scale: scale, in: context)
        case .arrow, .line:
            break
        case .pen, .text, .counter:
            drawSelectionOutline(frame: annotation.bounds.insetBy(dx: -4 / scale, dy: -4 / scale), scale: scale, in: context)
        }

        let handles = annotation.handles(magnification: scale)
        if !handles.isEmpty {
            drawHandles(handles.map(\.point), scale: scale, in: context)
        }
    }

    /// A dashed frame around the selected annotation. Drawn in white first
    /// and the accent colour on top, so it shows on any background.
    private func drawSelectionOutline(frame: CGRect, scale: CGFloat, in context: CGContext) {
        context.saveGState()
        context.setLineWidth(1.5 / scale)
        context.setStrokeColor(NSColor.white.cgColor)
        context.stroke(frame)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineDash(phase: 0, lengths: [5 / scale, 4 / scale])
        context.stroke(frame)
        context.restoreGState()
    }

    private func drawHandles(_ points: [CGPoint], scale: CGFloat, in context: CGContext) {
        let diameter = Annotation.handleDiameter / scale
        context.saveGState()
        context.setLineWidth(1.5 / scale)
        for point in points {
            let circle = CGRect(
                x: point.x - diameter / 2,
                y: point.y - diameter / 2,
                width: diameter,
                height: diameter
            )
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: circle)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.strokeEllipse(in: circle)
        }
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
            let rawPoint = unclampedImagePoint(of: event)
            if let selected = model.selectedAnnotation,
               let handle = selected.handle(at: point, magnification: zoomScale),
               let handleOrigin = selected.handles(magnification: zoomScale)
                   .first(where: { $0.handle == handle })?.point
            {
                activeResize = ResizeDrag(
                    original: selected,
                    handle: handle,
                    handleOrigin: handleOrigin,
                    pressPoint: rawPoint,
                    lastPoint: rawPoint,
                    current: selected
                )
                updateCursor(at: point)
                return
            }
            if model.select(at: point) {
                if event.clickCount == 2,
                   let selected = model.selectedAnnotation,
                   case .text(let string, let origin) = selected.shape
                {
                    beginText(at: origin, initialText: string, editingID: selected.id, clickPoint: point)
                } else {
                    moveStart = point
                }
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
        } else if activeResize != nil {
            activeResize?.didDrag = true
            updateResize(to: unclampedImagePoint(of: event), constrained: event.modifierFlags.contains(.shift))
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
        if let resize = activeResize, resize.didDrag {
            updateResize(to: unclampedImagePoint(of: event), constrained: event.modifierFlags.contains(.shift))
        }
        let finishedResize = activeResize
        let finishedMove = moveStart != nil ? moveOffset : nil
        let finishedCrop = cropDraft
        let finishedDraft = draft

        draft = nil
        cropDraft = nil
        dragStart = nil
        moveStart = nil
        moveOffset = .zero
        activeResize = nil

        if let finishedResize, finishedResize.didDrag {
            if Self.isLargeEnough(finishedResize.current.shape) {
                model.updateSelectedShape(finishedResize.current.shape)
            }
        } else if let finishedMove {
            model.moveSelected(by: finishedMove)
        } else if let finishedCrop {
            // Ignore a crop too small to be meant.
            if finishedCrop.width >= 8, finishedCrop.height >= 8 {
                model.crop(to: finishedCrop)
            }
        } else if let finishedDraft, Self.isLargeEnough(finishedDraft.shape) {
            model.add(finishedDraft.shape)
        }

        needsDisplay = true
        updateCursor(at: imagePoint(of: event))
    }

    private func updateResize(to rawPoint: CGPoint, constrained: Bool) {
        guard var resize = activeResize else { return }
        resize.lastPoint = rawPoint
        let target = CGPoint(
            x: resize.handleOrigin.x + (rawPoint.x - resize.pressPoint.x),
            y: resize.handleOrigin.y + (rawPoint.y - resize.pressPoint.y)
        )
        resize.current = resize.original.resized(
            dragging: resize.handle,
            to: target,
            constrained: constrained,
            within: model.visibleRect
        )
        activeResize = resize
    }

    private func makeDraft(_ shape: Annotation.Shape) -> Annotation {
        Annotation(shape: shape, color: model.color, size: model.size)
    }

    /// The event's position in image points, without clamping to the visible part.
    private func unclampedImagePoint(of event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let visible = model.visibleRect
        return CGPoint(x: point.x + visible.minX, y: point.y + visible.minY)
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
            if typingUndo.canUndo {
                typingUndo.undo()
                applyTextStyle()
            }
            syncTypingUndoState()
        } else {
            cancelDrag()
            model.undo()
        }
    }

    @objc func redo(_ sender: Any?) {
        if let typingUndo = textView?.undoManager {
            if typingUndo.canRedo {
                typingUndo.redo()
                applyTextStyle()
            }
            syncTypingUndoState()
        } else {
            cancelDrag()
            model.redo()
        }
    }

    override func flagsChanged(with event: NSEvent) {
        if let resize = activeResize, resize.didDrag {
            updateResize(to: resize.lastPoint, constrained: event.modifierFlags.contains(.shift))
            needsDisplay = true
        }
        super.flagsChanged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Delete, kVK_ForwardDelete:
            cancelDrag()
            model.deleteSelected()
        case kVK_Escape:
            if activeResize != nil || moveStart != nil {
                cancelDrag()
            } else {
                model.deselect()
            }
        default:
            super.keyDown(with: event)
        }
    }

    private func cancelDrag() {
        guard activeResize != nil || moveStart != nil else { return }
        activeResize = nil
        moveStart = nil
        moveOffset = .zero
        needsDisplay = true
        updateCursorForCurrentPointer()
    }

    // MARK: - Text tool

    private func beginText(
        at point: CGPoint,
        initialText: String = "",
        editingID: UUID? = nil,
        clickPoint: CGPoint? = nil
    ) {
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

        if let editingID {
            model.beginEditingText(id: editingID)
        }

        addSubview(textView)
        self.textView = textView
        textOrigin = point
        if !initialText.isEmpty {
            textView.string = initialText
        }
        applyTextStyle()
        window?.makeFirstResponder(textView)
        if !initialText.isEmpty {
            let caretIndex: Int
            if let clickPoint {
                let local = CGPoint(x: clickPoint.x - point.x, y: clickPoint.y - point.y)
                caretIndex = textView.characterIndexForInsertion(at: local)
            } else {
                caretIndex = (initialText as NSString).length
            }
            textView.setSelectedRange(NSRange(location: caretIndex, length: 0))
        }
        textView.undoManager?.removeAllActions()
        observeTypingUndo(for: textView)
        syncTypingUndoState()
    }

    private func applyTextStyle() {
        guard let textView else { return }
        let colorChoice = model.displayedColor ?? model.color
        let sizeChoice = model.displayedSize ?? model.size
        let attributes = AnnotationRenderer.textAttributes(color: colorChoice, size: sizeChoice)
        let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: sizeChoice.fontSize)
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
        let editingID = model.editingTextID
        // Clear these first: removing the view ends its editing session,
        // which calls back into this method.
        self.textView = nil
        textOrigin = nil
        stopObservingTypingUndo()
        textView.undoManager?.removeAllActions()
        model.clearTypingUndoState()

        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        textView.removeFromSuperview()
        if let editingID {
            model.finishEditingText(id: editingID, text: text)
        } else if !text.isEmpty {
            model.add(.text(text, origin: origin))
        }
        window?.makeFirstResponder(self)
    }

    private func observeTypingUndo(for textView: NSTextView) {
        stopObservingTypingUndo()
        guard let undoManager = textView.undoManager else { return }
        observedUndoManager = undoManager
        let center = NotificationCenter.default
        for name: Notification.Name in [
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange,
            .NSUndoManagerDidCloseUndoGroup,
        ] {
            center.addObserver(self, selector: #selector(typingUndoDidChange), name: name, object: undoManager)
        }
    }

    private func stopObservingTypingUndo() {
        guard let observedUndoManager else { return }
        let center = NotificationCenter.default
        for name: Notification.Name in [
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange,
            .NSUndoManagerDidCloseUndoGroup,
        ] {
            center.removeObserver(self, name: name, object: observedUndoManager)
        }
        self.observedUndoManager = nil
    }

    @objc private func typingUndoDidChange(_ notification: Notification) {
        syncTypingUndoState()
    }

    private func syncTypingUndoState() {
        guard let textView else { return }
        let undoManager = textView.undoManager
        model.setTypingUndoState(
            canUndo: undoManager?.canUndo ?? false,
            canRedo: undoManager?.canRedo ?? false
        )
    }

    func textDidChange(_ notification: Notification) {
        fitTextViewToText()
        syncTypingUndoState()
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
                owner: self
            )
        )
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: imagePoint(of: event))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: imagePoint(of: event))
    }

    override func mouseExited(with event: NSEvent) {
        if window?.isKeyWindow == true,
           activeResize == nil, moveStart == nil, dragStart == nil, draft == nil
        {
            NSCursor.arrow.set()
        }
        super.mouseExited(with: event)
    }

    private func updateCursorForCurrentPointer() {
        guard let window, window.isKeyWindow else { return }
        let viewPoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(viewPoint) else { return }
        let visible = model.visibleRect
        let imagePoint = CGPoint(x: viewPoint.x + visible.minX, y: viewPoint.y + visible.minY)
        updateCursor(at: imagePoint)
    }

    private func updateCursor(at point: CGPoint) {
        guard window?.isKeyWindow == true else { return }
        if let textView {
            let visible = model.visibleRect
            let viewPoint = CGPoint(x: point.x - visible.minX, y: point.y - visible.minY)
            if textView.frame.contains(viewPoint) {
                NSCursor.iBeam.set()
                return
            }
        }
        cursor(at: point).set()
    }

    private func cursor(at point: CGPoint) -> NSCursor {
        if let activeResize {
            return Self.cursor(for: activeResize.handle)
        }
        switch model.tool {
        case .select:
            if model.editingTextID == nil,
               let selected = model.selectedAnnotation,
               let handle = selected.handle(at: point, magnification: zoomScale)
            {
                return Self.cursor(for: handle)
            }
            return .arrow
        case .text:
            return .iBeam
        default:
            return .crosshair
        }
    }

    private static func cursor(for handle: Annotation.Handle) -> NSCursor {
        switch handle {
        case .start, .end:
            return .crosshair
        case .topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left:
            if #available(macOS 15.0, *) {
                let position: NSCursor.FrameResizePosition = switch handle {
                case .topLeft: .topLeft
                case .top: .top
                case .topRight: .topRight
                case .right: .right
                case .bottomRight: .bottomRight
                case .bottom: .bottom
                case .bottomLeft: .bottomLeft
                case .left: .left
                case .start, .end: .topLeft
                }
                return .frameResize(position: position, directions: .all)
            }
            // macOS 14 has no diagonal frame-resize cursors; macOS 15+ uses `.frameResize` above.
            switch handle {
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            case .topLeft, .topRight, .bottomLeft, .bottomRight, .start, .end: return .crosshair
            }
        }
    }
}
