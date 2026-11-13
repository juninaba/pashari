import CoreGraphics

extension Annotation {
    /// How far outside a mark a click may land and still count as hitting it.
    static let hitSlop: CGFloat = 4

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
