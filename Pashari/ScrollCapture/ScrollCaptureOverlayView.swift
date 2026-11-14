import AppKit

/// Shows which area is being recorded: the rest of the screen is dimmed,
/// and the area gets a border just outside it. The view takes no input; the
/// panel it sits in lets every click and scroll through.
final class ScrollCaptureOverlayView: NSView {
    /// In this view's coordinates, origin at the top-left corner.
    let area: CGRect

    init(frame: CGRect, area: CGRect) {
        self.area = area
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ScrollCaptureOverlayView is created in code only")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.setFillColor(NSColor.black.withAlphaComponent(0.2).cgColor)
        context.addRect(bounds)
        context.addRect(area)
        context.fillPath(using: .evenOdd)

        // Two points wide, entirely outside the area, so that none of it
        // could end up in the picture.
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(2)
        context.stroke(area.insetBy(dx: -1, dy: -1))
    }
}
