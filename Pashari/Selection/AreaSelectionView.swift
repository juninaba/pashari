import AppKit
import Carbon.HIToolbox

/// Dims the frozen screen and lets the user drag out a rectangle.
///
/// The view only draws the dimming, the selection border and the size label.
/// The frozen screenshot itself sits in the view underneath.
final class AreaSelectionView: NSView {
    /// Called once, with the selected rectangle in points (origin at the
    /// top-left corner of the screen), or nil when the user cancelled.
    var onFinish: ((CGRect?) -> Void)?

    /// Pixels per point of the screen this view covers.
    private let scale: CGFloat
    private var dragStart: CGPoint?
    private var selection: CGRect?

    init(frame: CGRect, scale: CGFloat) {
        self.scale = scale
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AreaSelectionView is created in code only")
    }

    // Top-left origin with y growing downwards, like CGImage and like the web.
    // AppKit's default is bottom-left with y growing upwards.
    override var isFlipped: Bool { true }

    // Take keyboard input, and react to the very first click even though the
    // panel was not focused before it.
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.setFillColor(NSColor.black.withAlphaComponent(0.3).cgColor)
        guard let selection else {
            context.fill(bounds)
            return
        }

        // Dim everything except the selection: with the even-odd rule, the
        // inner rectangle becomes a hole in the outer one.
        context.addRect(bounds)
        context.addRect(selection)
        context.fillPath(using: .evenOdd)

        // A one-point border just outside the selected pixels.
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.stroke(selection.insetBy(dx: -0.5, dy: -0.5))

        drawSizeLabel(for: selection)
    }

    private func drawSizeLabel(for selection: CGRect) {
        let text = "\(Int(selection.width)) × \(Int(selection.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let padding = CGSize(width: 6, height: 3)
        var box = CGRect(
            x: selection.maxX - textSize.width - padding.width * 2,
            y: selection.maxY + 6,
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height * 2
        )
        // Keep the label on screen when the selection touches an edge.
        if box.maxY > bounds.maxY { box.origin.y = selection.maxY - box.height - 6 }
        if box.minX < bounds.minX { box.origin.x = bounds.minX }

        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(
            at: CGPoint(x: box.minX + padding.width, y: box.minY + padding.height),
            withAttributes: attributes
        )
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        dragStart = location(of: event)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        selection = Self.rect(from: dragStart, to: location(of: event))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        // A plain click, or a drag too small to be intended, selects nothing
        // and leaves the overlay open for another try.
        guard let selection, selection.width >= 2, selection.height >= 2 else {
            self.selection = nil
            needsDisplay = true
            return
        }
        onFinish?(selection)
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish?(nil)
    }

    /// The event's position in this view, kept inside the view and snapped to
    /// whole pixels so the selection border never falls between two pixels.
    private func location(of event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: (min(max(point.x, bounds.minX), bounds.maxX) * scale).rounded() / scale,
            y: (min(max(point.y, bounds.minY), bounds.maxY) * scale).rounded() / scale
        )
    }

    /// The rectangle spanned by two corners, whichever direction the drag went.
    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            onFinish?(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // `.activeAlways`: deliver these events even though Pashari is not the
        // active app.
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .inVisibleRect, .mouseMoved, .cursorUpdate],
                owner: self
            )
        )
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
    }
}
