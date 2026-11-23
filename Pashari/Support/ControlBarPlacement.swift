import CoreGraphics

/// Where the small bar of a scroll capture or a recording goes, next to
/// the area it is about.
enum ControlBarPlacement {
    static let gap: CGFloat = 12

    /// Centred under the area, or over it when there is no room below, or
    /// else inside its bottom edge. Everything is in AppKit screen
    /// coordinates, where y grows upwards.
    static func frame(ofSize size: CGSize, nextTo area: CGRect, in visibleFrame: CGRect) -> CGRect {
        var origin = CGPoint(x: area.midX - size.width / 2, y: area.minY - gap - size.height)
        if origin.y < visibleFrame.minY {
            origin.y = area.maxY + gap
            if origin.y + size.height > visibleFrame.maxY {
                origin.y = max(area.minY, visibleFrame.minY) + gap
            }
        }
        origin.x = min(max(origin.x, visibleFrame.minX + gap), visibleFrame.maxX - gap - size.width)
        return CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
    }
}
