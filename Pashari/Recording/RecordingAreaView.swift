import AppKit
import Carbon.HIToolbox

/// One screen's overlay while the area to record is chosen. Unlike area
/// selection, there is no frozen screenshot underneath: the screen goes on
/// as it is, dimmed outside the frame, so that the user sees what will be
/// recorded.
///
/// The frame, and what drags do to it, live in `RecordingFrameEditor`,
/// which the recording session holds for all screens. This view draws the
/// frame when it is on this screen, and passes the mouse on.
final class RecordingAreaView: SelectionOverlayView {
    /// The frame on this screen, in this view's coordinates, or nil.
    var frameRect: CGRect? {
        didSet {
            if frameRect != oldValue { needsDisplay = true }
        }
    }

    /// What a press at a point would take hold of.
    var region: ((CGPoint) -> RecordingFrameEditor.Region)?
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: (() -> Void)?
    /// Return or Enter.
    var onRecord: (() -> Void)?

    private var pointer: CGPoint?
    private var isMoving = false

    static let handleDiameter: CGFloat = 9

    override var isFlipped: Bool { true }

    override var cursor: NSCursor {
        guard let pointer, let region = region?(pointer) else { return .crosshair }
        switch region {
        case .outside:
            return .crosshair
        case .inside:
            return isMoving ? .closedHand : .openHand
        case .handle(let handle):
            return Self.cursor(for: handle)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.setFillColor(NSColor.black.withAlphaComponent(0.3).cgColor)
        guard let frameRect else {
            context.fill(bounds)
            return
        }
        // With the even-odd rule, the frame becomes a hole in the dimming.
        context.addRect(bounds)
        context.addRect(frameRect)
        context.fillPath(using: .evenOdd)

        // A one-point border just outside the recorded pixels.
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.stroke(frameRect.insetBy(dx: -0.5, dy: -0.5))

        let diameter = Self.handleDiameter
        for point in Self.handlePoints(of: frameRect) {
            let circle = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter)
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: circle)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
            context.strokeEllipse(in: circle.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    /// The corners and the middle of each edge.
    static func handlePoints(of rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY),
        ]
    }

    // MARK: - Mouse and keyboard

    override func mouseMoved(with event: NSEvent) {
        pointer = location(of: event)
        super.mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = location(of: event)
        pointer = point
        isMoving = region?(point) == .inside
        cursor.set()
        onMouseDown?(point)
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseDragged?(location(of: event))
    }

    override func mouseUp(with event: NSEvent) {
        isMoving = false
        onMouseUp?()
        pointer = location(of: event)
        cursor.set()
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            onRecord?()
        default:
            super.keyDown(with: event)
        }
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private static func cursor(for handle: RecordingFrameEditor.Handle) -> NSCursor {
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
            }
            return .frameResize(position: position, directions: .all)
        }
        // macOS 14 has no cursors for the corners.
        switch handle {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return .crosshair
        }
    }
}
