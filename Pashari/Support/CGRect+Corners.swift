import CoreGraphics

extension CGRect {
    /// The rectangle spanned by two opposite corners, whichever way round
    /// they are given. This is what a mouse drag produces: it can go in any
    /// direction, but a rectangle needs a top-left origin and a positive size.
    init(corner a: CGPoint, oppositeCorner b: CGPoint) {
        self.init(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }
}
