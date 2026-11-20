import CoreGraphics

/// The frame the user adjusts before recording, and what their drags do to
/// it: a drag outside the frame draws a new one, a drag inside moves it,
/// and a drag on an edge or a corner moves that edge or corner.
///
/// There is one overlay for each screen, and the frame lies on one of them
/// at a time. Points are in the screen's points, with the origin at its
/// top-left corner, and are kept to whole points: ScreenCaptureKit would
/// scale the frames of an area that ends partway through a point, which
/// blurs them.
struct RecordingFrameEditor {
    struct Placement: Equatable {
        /// Which screen's overlay the frame is on.
        var screen: Int
        var rect: CGRect
    }

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    enum Region: Equatable {
        case outside
        case inside
        case handle(Handle)
    }

    /// Smaller frames are taken for a slip of the mouse.
    static let minimumSide: CGFloat = 16
    /// How near a corner a press takes hold of it.
    static let cornerReach: CGFloat = 10
    /// How near an edge a press takes hold of it.
    static let edgeReach: CGFloat = 6

    /// The frame as it shows now, also while it is dragged.
    private(set) var frame: Placement?

    /// The frame as it was before the drag in progress.
    private var settled: Placement?
    private var drag: Drag?

    private enum Drag {
        case drawing(screen: Int, from: CGPoint, bounds: CGRect)
        case moving(from: CGPoint, original: CGRect, bounds: CGRect)
        case resizing(Handle, original: CGRect, bounds: CGRect)
    }

    init(frame: Placement? = nil) {
        self.frame = frame
        settled = frame
    }

    var isDragging: Bool { drag != nil }

    /// What a press at `point` on `screen` would take hold of.
    func region(at point: CGPoint, on screen: Int) -> Region {
        guard let frame, frame.screen == screen else { return .outside }
        let rect = frame.rect
        let corners: [(Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
        ]
        for (handle, corner) in corners
        where abs(point.x - corner.x) <= Self.cornerReach && abs(point.y - corner.y) <= Self.cornerReach {
            return .handle(handle)
        }
        let alongX = point.x >= rect.minX && point.x <= rect.maxX
        let alongY = point.y >= rect.minY && point.y <= rect.maxY
        if alongX, abs(point.y - rect.minY) <= Self.edgeReach { return .handle(.top) }
        if alongX, abs(point.y - rect.maxY) <= Self.edgeReach { return .handle(.bottom) }
        if alongY, abs(point.x - rect.minX) <= Self.edgeReach { return .handle(.left) }
        if alongY, abs(point.x - rect.maxX) <= Self.edgeReach { return .handle(.right) }
        return rect.contains(point) ? .inside : .outside
    }

    /// A press at `point` on `screen`, whose overlay covers `bounds`.
    mutating func begin(at point: CGPoint, on screen: Int, in bounds: CGRect) {
        let point = Self.clamped(point, to: bounds)
        switch region(at: point, on: screen) {
        case .outside:
            drag = .drawing(screen: screen, from: point, bounds: bounds)
        case .inside:
            drag = frame.map { .moving(from: point, original: $0.rect, bounds: bounds) }
        case .handle(let handle):
            drag = frame.map { .resizing(handle, original: $0.rect, bounds: bounds) }
        }
    }

    mutating func move(to point: CGPoint) {
        switch drag {
        case .drawing(let screen, let start, let bounds):
            let point = Self.clamped(point, to: bounds)
            frame = Placement(screen: screen, rect: CGRect(corner: start, oppositeCorner: point))
        case .moving(let start, let original, let bounds):
            frame?.rect = Self.moved(original, by: CGSize(width: point.x - start.x, height: point.y - start.y), within: bounds)
        case .resizing(let handle, let original, let bounds):
            frame?.rect = Self.resized(original, dragging: handle, to: Self.clamped(point, to: bounds))
        case nil:
            break
        }
    }

    /// The end of a drag. A frame drawn too small to be meant gives way to
    /// the one there was before.
    mutating func end() {
        if case .drawing = drag, let frame, !Self.isLargeEnough(frame.rect) {
            self.frame = settled
        }
        settled = frame
        drag = nil
    }

    // MARK: - Geometry

    static func isLargeEnough(_ rect: CGRect) -> Bool {
        rect.width >= minimumSide && rect.height >= minimumSide
    }

    /// `rect` moved by `offset`, as far as it fits inside `bounds`.
    static func moved(_ rect: CGRect, by offset: CGSize, within bounds: CGRect) -> CGRect {
        var origin = CGPoint(x: (rect.minX + offset.width).rounded(), y: (rect.minY + offset.height).rounded())
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - rect.width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - rect.height)
        return CGRect(origin: origin, size: rect.size)
    }

    /// `rect` with the edges that `handle` holds moved to `point`, and the
    /// others where they were. It keeps the smallest size.
    static func resized(_ rect: CGRect, dragging handle: Handle, to point: CGPoint) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .left, .topLeft, .bottomLeft:
            minX = min(point.x, maxX - minimumSide)
        case .right, .topRight, .bottomRight:
            maxX = max(point.x, minX + minimumSide)
        case .top, .bottom:
            break
        }
        switch handle {
        case .top, .topLeft, .topRight:
            minY = min(point.y, maxY - minimumSide)
        case .bottom, .bottomLeft, .bottomRight:
            maxY = max(point.y, minY + minimumSide)
        case .left, .right:
            break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// `point` inside `bounds`, on whole points.
    static func clamped(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x.rounded(), bounds.minX), bounds.maxX),
            y: min(max(point.y.rounded(), bounds.minY), bounds.maxY)
        )
    }
}
