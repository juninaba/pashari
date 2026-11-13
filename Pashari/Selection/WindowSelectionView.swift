import AppKit

/// A see-through layer over one screen that highlights the window under the
/// pointer. The live desktop stays visible underneath.
final class WindowSelectionView: SelectionOverlayView {
    /// The highlighted window's frame in this view's coordinates, or nil when
    /// the pointer is not over a window.
    var highlightFrame: CGRect? {
        didSet {
            if highlightFrame != oldValue { needsDisplay = true }
        }
    }

    /// Called whenever the pointer moves over this screen.
    var onPointerMove: (() -> Void)?

    /// Called when the user clicks.
    var onClick: (() -> Void)?

    // A click picks the whole window, so the pointer need not be precise.
    // The camera makes it clear that Pashari is waiting for that click.
    override var cursor: NSCursor { .camera }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Dim the screen lightly, leaving the highlighted window clear.
        context.setFillColor(NSColor.black.withAlphaComponent(0.2).cgColor)
        context.addRect(bounds)
        if let highlightFrame {
            context.addRect(highlightFrame)
        }
        context.fillPath(using: .evenOdd)

        if let highlightFrame {
            let border = NSBezierPath(rect: highlightFrame.insetBy(dx: 1.5, dy: 1.5))
            border.lineWidth = 3
            NSColor.controlAccentColor.setStroke()
            border.stroke()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerMove?()
    }

    override func mouseDown(with event: NSEvent) {
        // The pointer may have been placed without a move event reaching us.
        onPointerMove?()
        onClick?()
    }
}
