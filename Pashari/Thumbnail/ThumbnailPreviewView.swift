import AppKit

/// The picture part of a thumbnail card. It can be dragged into other apps,
/// which receive the screenshot as a PNG file.
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

        // Let Core Animation draw the image, scaled to fit with its
        // proportions kept.
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

    // React to the first click even though the panel never has focus.
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

        // The dragged data is the file's URL, which is what Finder, mail
        // clients, chat apps and browsers all understand.
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
        // The receiver gets a copy; the temporary file stays where it is.
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        // An empty operation means nobody took the drop.
        if !operation.isEmpty {
            onDrop?()
        }
    }

    // MARK: - Geometry

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// The largest rectangle with the proportions of `size` that fits inside
    /// `bounds`, centred.
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
