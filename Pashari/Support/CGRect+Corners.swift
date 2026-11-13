import CoreGraphics

extension CGRect {
    init(corner a: CGPoint, oppositeCorner b: CGPoint) {
        self.init(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    func snappedToPixels(scale: CGFloat) -> CGRect {
        func snap(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded() / scale
        }
        // The edges are rounded one by one, not the origin and the size, so
        // that an edge never moves by more than half a pixel.
        let left = snap(minX)
        let top = snap(minY)
        return CGRect(x: left, y: top, width: snap(maxX) - left, height: snap(maxY) - top)
    }
}
