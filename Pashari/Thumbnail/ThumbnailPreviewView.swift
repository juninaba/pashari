import AppKit

final class ThumbnailPreviewView: NSView, NSDraggingSource {
    /// Asked when a drag starts. Returns nil while the file is not ready yet,
    /// in which case the drag does not begin.
    var fileURL: (() -> URL?)?

    /// Called after a drop that the receiving app accepted.
    var onDrop: (() -> Void)?

    private var image: CGImage?
    private var mouseDownEvent: NSEvent?

    override init(frame: CGRect) {
        super.init(frame: frame)

        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ThumbnailPreviewView is created in code only")
    }

    func show(_ image: CGImage) {
        self.image = image
        layer?.contents = image
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Starting a drag

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    override func mouseDragged(with event: NSEvent) {
        // Start only after the pointer has clearly moved, so a slightly
        // shaky click is not mistaken for a drag.
        guard
            let mouseDownEvent,
            Self.distance(mouseDownEvent.locationInWindow, event.locationInWindow) >= 4,
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
        if !operation.isEmpty {
            onDrop?()
        }
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
