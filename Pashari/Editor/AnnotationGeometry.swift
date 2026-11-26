import CoreGraphics

extension Annotation {
    enum Handle: Equatable, Hashable {
        case start, end
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    /// How far outside a mark a click may land and still count as hitting it.
    static let hitSlop: CGFloat = 4
    /// Visual diameter of a resize handle on screen, in points.
    static let handleDiameter: CGFloat = 9
    /// Hit radius around a resize handle's centre on screen, in points.
    static let handleHitRadius: CGFloat = 7
    /// Minimum edge length on screen before side handles are shown, leaving
    /// a free stroke gap between corner and side hit areas (4 * hitRadius + 16).
    static let minimumEdgeForSideHandle: CGFloat = 44
    /// Smallest width or height a box may be resized down to, in image points.
    static let minimumResizeSide: CGFloat = 3

    /// The smallest rectangle that contains the whole mark, including the
    /// thickness of its stroke.
    var bounds: CGRect {
        switch shape {
        case .arrow(let from, let to):
            // The head is wider than the shaft.
            let head = AnnotationRenderer.arrowHead(from: from, to: to, lineWidth: size.lineWidth)
            let points = [from, to, head.left, head.right]
            return Self.boundingBox(of: points).insetBy(dx: -size.lineWidth / 2, dy: -size.lineWidth / 2)
        case .line(let from, let to):
            return CGRect(corner: from, oppositeCorner: to)
                .insetBy(dx: -size.lineWidth / 2, dy: -size.lineWidth / 2)
        case .rectangle(let rect), .ellipse(let rect):
            return rect.insetBy(dx: -size.lineWidth / 2, dy: -size.lineWidth / 2)
        case .pen(let points):
            return Self.boundingBox(of: points)
                .insetBy(dx: -size.lineWidth / 2, dy: -size.lineWidth / 2)
        case .text(let string, let origin):
            return CGRect(origin: origin, size: AnnotationRenderer.textSize(of: string, size: size))
        case .blur(let rect):
            return rect
        case .counter(_, let center):
            let radius = size.counterRadius
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }
    }

    /// Outlines (rectangle, ellipse) are hit only near their stroke, not in
    /// the empty middle, so that marks inside a big frame stay reachable.
    func isHit(at point: CGPoint) -> Bool {
        let reach = size.lineWidth / 2 + Self.hitSlop

        switch shape {
        case .arrow(let from, let to):
            let head = AnnotationRenderer.arrowHead(from: from, to: to, lineWidth: size.lineWidth)
            let headBox = Self.boundingBox(of: [to, head.left, head.right])
                .insetBy(dx: -Self.hitSlop, dy: -Self.hitSlop)
            return Self.distance(from: point, toSegment: from, to) <= reach || headBox.contains(point)
        case .line(let from, let to):
            return Self.distance(from: point, toSegment: from, to) <= reach
        case .rectangle(let rect):
            let outer = rect.insetBy(dx: -reach, dy: -reach)
            // `insetBy` returns the "null" rectangle when the inset would
            // turn the rectangle inside out; nothing is inside that.
            let inner = rect.insetBy(dx: reach, dy: reach)
            return outer.contains(point) && !inner.contains(point)
        case .ellipse(let rect):
            return Self.isPoint(point, within: reach, of: CGPath(ellipseIn: rect, transform: nil))
        case .pen(let points):
            return Self.isPoint(point, within: reach, of: AnnotationRenderer.smoothPath(through: points))
        case .text, .blur, .counter:
            return bounds.insetBy(dx: -Self.hitSlop, dy: -Self.hitSlop).contains(point)
        }
    }

    /// Resize handles for this mark, in image points. Side handles are omitted
    /// when either side is too short on screen to leave room between corners
    /// and across opposite edges.
    func handles(magnification: CGFloat = 1) -> [(handle: Handle, point: CGPoint)] {
        let scale = max(magnification, 0.01)
        switch shape {
        case .arrow(let from, let to), .line(let from, let to):
            return [(.start, from), (.end, to)]
        case .rectangle(let rect), .ellipse(let rect), .blur(let rect):
            var result: [(Handle, CGPoint)] = [
                (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
                (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
                (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
                (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            ]
            if min(rect.width, rect.height) * scale >= Self.minimumEdgeForSideHandle {
                result.append((.top, CGPoint(x: rect.midX, y: rect.minY)))
                result.append((.bottom, CGPoint(x: rect.midX, y: rect.maxY)))
                result.append((.left, CGPoint(x: rect.minX, y: rect.midY)))
                result.append((.right, CGPoint(x: rect.maxX, y: rect.midY)))
            }
            return result
        case .pen, .text, .counter:
            return []
        }
    }

    /// The nearest resize handle within screen-constant reach of `point`.
    /// Keeps the full visible handle reachable from outside while leaving the
    /// middle of a short or zoomed-out mark free to drag and move.
    func handle(at point: CGPoint, magnification: CGFloat = 1) -> Handle? {
        let scale = max(magnification, 0.01)
        let radius = Self.handleHitRadius / scale

        switch shape {
        case .arrow(let from, let to), .line(let from, let to):
            let dx = to.x - from.x
            let dy = to.y - from.y
            let lengthSquared = dx * dx + dy * dy
            if lengthSquared > 0, isHit(at: point) {
                let t = ((point.x - from.x) * dx + (point.y - from.y) * dy) / lengthSquared
                if t > 1.0 / 3.0 && t < 2.0 / 3.0 {
                    return nil
                }
            }
        case .rectangle(let rect), .ellipse(let rect), .blur(let rect):
            if min(rect.width, rect.height) * scale < Self.minimumEdgeForSideHandle, isHit(at: point) {
                let inMiddle = rect.width >= rect.height
                    ? point.x > rect.minX + rect.width / 3 && point.x < rect.maxX - rect.width / 3
                    : point.y > rect.minY + rect.height / 3 && point.y < rect.maxY - rect.height / 3
                if inMiddle {
                    return nil
                }
            }
        case .pen, .text, .counter:
            return nil
        }

        var best: (handle: Handle, distance: CGFloat)?
        for (handle, handlePoint) in handles(magnification: scale) {
            let distance = hypot(point.x - handlePoint.x, point.y - handlePoint.y)
            if distance <= radius, best == nil || distance < best!.distance {
                best = (handle, distance)
            }
        }
        return best?.handle
    }

    /// A copy with `handle` dragged to `point`, staying inside `bounds`.
    /// When `constrained` is true, arrows and lines snap in 45° steps, and
    /// dragging a corner of a rectangle or ellipse makes it a square or circle.
    func resized(
        dragging handle: Handle,
        to point: CGPoint,
        constrained: Bool = false,
        within bounds: CGRect
    ) -> Annotation {
        var copy = self
        let clamped = Self.clamped(point, to: bounds)
        switch shape {
        case .arrow(let from, let to):
            switch handle {
            case .start:
                let moved = constrained
                    ? Self.constrainedEndpoint(tool: .arrow, from: to, to: point, fallback: clamped, within: bounds)
                    : clamped
                copy.shape = .arrow(from: moved, to: to)
            case .end:
                let moved = constrained
                    ? Self.constrainedEndpoint(tool: .arrow, from: from, to: point, fallback: clamped, within: bounds)
                    : clamped
                copy.shape = .arrow(from: from, to: moved)
            default:
                break
            }
        case .line(let from, let to):
            switch handle {
            case .start:
                let moved = constrained
                    ? Self.constrainedEndpoint(tool: .line, from: to, to: point, fallback: clamped, within: bounds)
                    : clamped
                copy.shape = .line(from: moved, to: to)
            case .end:
                let moved = constrained
                    ? Self.constrainedEndpoint(tool: .line, from: from, to: point, fallback: clamped, within: bounds)
                    : clamped
                copy.shape = .line(from: from, to: moved)
            default:
                break
            }
        case .rectangle(let rect):
            copy.shape = .rectangle(
                Self.resizedRect(rect, dragging: handle, to: clamped, square: constrained, within: bounds)
            )
        case .ellipse(let rect):
            copy.shape = .ellipse(
                Self.resizedRect(rect, dragging: handle, to: clamped, square: constrained, within: bounds)
            )
        case .blur(let rect):
            copy.shape = .blur(
                Self.resizedRect(rect, dragging: handle, to: clamped, square: false, within: bounds)
            )
        case .pen, .text, .counter:
            break
        }
        return copy
    }

    func translated(by offset: CGSize) -> Annotation {
        func moved(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x + offset.width, y: point.y + offset.height)
        }
        func moved(_ rect: CGRect) -> CGRect {
            rect.offsetBy(dx: offset.width, dy: offset.height)
        }

        var copy = self
        switch shape {
        case .arrow(let from, let to): copy.shape = .arrow(from: moved(from), to: moved(to))
        case .line(let from, let to): copy.shape = .line(from: moved(from), to: moved(to))
        case .rectangle(let rect): copy.shape = .rectangle(moved(rect))
        case .ellipse(let rect): copy.shape = .ellipse(moved(rect))
        case .pen(let points): copy.shape = .pen(points.map(moved))
        case .text(let string, let origin): copy.shape = .text(string, origin: moved(origin))
        case .blur(let rect): copy.shape = .blur(moved(rect))
        case .counter(let number, let center): copy.shape = .counter(number, center: moved(center))
        }
        return copy
    }

    // MARK: - Helpers

    private static func clamped(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private static func isInside(_ point: CGPoint, bounds: CGRect) -> Bool {
        let epsilon: CGFloat = 1e-6
        return point.x >= bounds.minX - epsilon && point.x <= bounds.maxX + epsilon
            && point.y >= bounds.minY - epsilon && point.y <= bounds.maxY + epsilon
    }

    /// Snaps a dragged endpoint to 45° steps, falling back to `fallback` if an
    /// off-crop anchor would snap the dragged endpoint outside `bounds`.
    private static func constrainedEndpoint(
        tool: EditorTool,
        from anchor: CGPoint,
        to point: CGPoint,
        fallback: CGPoint,
        within bounds: CGRect
    ) -> CGPoint {
        let snapped = tool.constrainedEnd(from: anchor, to: point, within: bounds)
        return isInside(snapped, bounds: bounds) ? snapped : fallback
    }

    /// Clamps dragged edges to `minimumResizeSide` instead of flipping the box
    /// inside out, matching `RecordingFrameEditor.resized`.
    private static func resizedRect(
        _ rect: CGRect,
        dragging handle: Handle,
        to point: CGPoint,
        square: Bool,
        within bounds: CGRect
    ) -> CGRect {
        let minSide = minimumResizeSide
        if square, let (anchor, sx, sy) = cornerAnchor(for: handle, in: rect) {
            let dx = (point.x - anchor.x) * sx
            let dy = (point.y - anchor.y) * sy
            let roomX = sx > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
            let roomY = sy > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
            let side = max(min(max(dx, dy), roomX, roomY), minSide)
            let corner = CGPoint(x: anchor.x + sx * side, y: anchor.y + sy * side)
            return CGRect(corner: anchor, oppositeCorner: corner)
        }

        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .left, .topLeft, .bottomLeft:
            minX = min(point.x, maxX - minSide)
        case .right, .topRight, .bottomRight:
            maxX = max(point.x, minX + minSide)
        case .top, .bottom, .start, .end:
            break
        }
        switch handle {
        case .top, .topLeft, .topRight:
            minY = min(point.y, maxY - minSide)
        case .bottom, .bottomLeft, .bottomRight:
            maxY = max(point.y, minY + minSide)
        case .left, .right, .start, .end:
            break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func cornerAnchor(for handle: Handle, in rect: CGRect) -> (CGPoint, CGFloat, CGFloat)? {
        switch handle {
        case .topLeft: (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1)
        case .topRight: (CGPoint(x: rect.minX, y: rect.maxY), 1, -1)
        case .bottomRight: (CGPoint(x: rect.minX, y: rect.minY), 1, 1)
        case .bottomLeft: (CGPoint(x: rect.maxX, y: rect.minY), -1, 1)
        default: nil
        }
    }

    static func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }

        // How far along the segment the closest point lies: 0 at `a`, 1 at
        // `b`, clamped so it never runs past either end.
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    /// Whether `point` is within `reach` of the line drawn along `path`.
    static func isPoint(_ point: CGPoint, within reach: CGFloat, of path: CGPath) -> Bool {
        path.copy(strokingWithWidth: reach * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
            .contains(point)
    }
}
