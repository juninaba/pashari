import AppKit

/// Keeps the image in the middle of the scroll view when it is smaller than
/// the visible area. By default a scroll view pins its content to a corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let documentFrame = documentView?.frame else { return bounds }

        if documentFrame.width < bounds.width {
            bounds.origin.x = documentFrame.midX - bounds.width / 2
        }
        if documentFrame.height < bounds.height {
            bounds.origin.y = documentFrame.midY - bounds.height / 2
        }
        return bounds
    }
}
