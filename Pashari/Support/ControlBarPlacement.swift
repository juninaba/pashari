import CoreGraphics

/// Where the small bar of a scroll capture or a recording goes, next to
/// the area it is about.
enum ControlBarPlacement {
    static let gap: CGFloat = 12

    /// Centred under the area, or over it when there is no room below, or
    /// beside it (right, then left) when neither fits, or else inside its
    /// bottom edge. Everything is in AppKit screen coordinates, where y grows
    /// upwards.
    static func frame(ofSize size: CGSize, nextTo area: CGRect, in visibleFrame: CGRect) -> CGRect {
        let centeredX = clamp(
            area.midX - size.width / 2,
            min: visibleFrame.minX + gap,
            max: visibleFrame.maxX - gap - size.width
        )
        let belowY = area.minY - gap - size.height
        if belowY >= visibleFrame.minY {
            return CGRect(origin: CGPoint(x: centeredX.rounded(), y: belowY.rounded()), size: size)
        }
        let aboveY = area.maxY + gap
        if aboveY + size.height <= visibleFrame.maxY {
            return CGRect(origin: CGPoint(x: centeredX.rounded(), y: aboveY.rounded()), size: size)
        }
        let sideY = clamp(
            area.minY,
            min: visibleFrame.minY + gap,
            max: visibleFrame.maxY - gap - size.height
        )
        let rightX = area.maxX + gap
        if rightX + size.width <= visibleFrame.maxX - gap {
            return CGRect(origin: CGPoint(x: rightX.rounded(), y: sideY.rounded()), size: size)
        }
        let leftX = area.minX - gap - size.width
        if leftX >= visibleFrame.minX + gap {
            return CGRect(origin: CGPoint(x: leftX.rounded(), y: sideY.rounded()), size: size)
        }
        let insideY = max(area.minY, visibleFrame.minY) + gap
        return CGRect(origin: CGPoint(x: centeredX.rounded(), y: insideY.rounded()), size: size)
    }

    private static func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        guard lower <= upper else { return lower }
        return min(max(value, lower), upper)
    }
}
