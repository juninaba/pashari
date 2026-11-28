import AppKit

/// The part of a card that the picture can be dragged out of, or
/// double-clicked to open. It draws nothing itself: the card shows the
/// picture (see `ThumbnailCardView`).
final class ThumbnailPreviewView: NSView, NSDraggingSource {
    /// Asked when a drag starts. Returns nil while the file is not ready yet,
    /// in which case the drag does not begin.
    var fileURL: (() -> URL?)?

    /// Called after a drop that the receiving app accepted.
    var onDrop: (() -> Void)?

    /// Called when a drag ends, dropped or not.
    var onDragEnd: (() -> Void)?

    /// Called when the second click of a double-click on the picture ends
    /// where it began. A second click that moves off drags the picture.
    var onDoubleClick: (() -> Void)?

    /// How far the pointer moves with the button down before it drags the
    /// picture.
    private static let dragDistance: CGFloat = 4

    /// The picture, for the image that follows the pointer while dragging.
    private var image: CGImage?
    private var mouseDownEvent: NSEvent?

    /// True from the start of a drag until it ends, dropped or not.
    private(set) var isDragging = false

    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ThumbnailPreviewView is created in code only")
    }

    func show(_ image: CGImage) {
        self.image = image
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Opening and starting a drag

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        // AppKit sends the second click to the view that took the first,
        // even if the cards have moved since: a first click that spread
        // the pile out cannot open a card that came under the pointer.
        guard
            event.clickCount == 2,
            let mouseDownEvent,
            Self.distance(mouseDownEvent.locationInWindow, event.locationInWindow) < Self.dragDistance
        else {
            return
        }
        onDoubleClick?()
    }

    override func mouseDragged(with event: NSEvent) {
        // Start only after the pointer has clearly moved, so a slightly
        // shaky click is not mistaken for a drag.
        guard
            let mouseDownEvent,
            Self.distance(mouseDownEvent.locationInWindow, event.locationInWindow) >= Self.dragDistance,
            let url = fileURL?(),
            let image
        else {
            return
        }
        self.mouseDownEvent = nil

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let pictureFrame = Self.aspectFit(
            CGSize(width: image.width, height: image.height),
            in: bounds
        )
        item.setDraggingFrame(pictureFrame, contents: NSImage(cgImage: image, size: pictureFrame.size))
        isDragging = true
        beginDraggingSession(with: [item], event: mouseDownEvent, source: self)
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        dragDidEnd(operation: operation)
    }

    func dragDidEnd(operation: NSDragOperation) {
        isDragging = false
        if !operation.isEmpty {
            onDrop?()
        }
        onDragEnd?()
    }

    // MARK: - Geometry

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    static func aspectFit(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let factor = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * factor, height: size.height * factor)
        return CGRect(
            x: bounds.midX - fitted.width / 2,
            y: bounds.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}
