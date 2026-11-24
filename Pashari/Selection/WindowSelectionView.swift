import AppKit

final class WindowSelectionView: SelectionOverlayView {
    /// The highlighted window's frame in this view's coordinates, or nil when
    /// the pointer is not over a window.
    var highlightFrame: CGRect? {
        didSet {
            if highlightFrame != oldValue { needsDisplay = true }
        }
    }

    var onPointerMove: (() -> Void)?

    var onClick: (() -> Void)?

    private let selectionCursor: NSCursor

    init(frame: CGRect, cursor: NSCursor = .camera) {
        selectionCursor = cursor
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WindowSelectionView is created in code only")
    }

    override var cursor: NSCursor { selectionCursor }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

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
