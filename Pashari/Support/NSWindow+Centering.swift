import AppKit

extension NSWindow {
    /// `center()` cannot be told which screen to use. It takes the one the
    /// window is on, which for a window that has not been shown yet is the
    /// main display, even when the user is working on another one.
    func center(on screen: NSScreen) {
        setFrameOrigin(Self.originCentering(frame.size, in: screen.visibleFrame))
    }

    /// Where a window of `size` goes to sit in the middle of `area`. A window
    /// taller than the area keeps its title bar inside it.
    static func originCentering(_ size: CGSize, in area: CGRect) -> CGPoint {
        CGPoint(
            x: (area.midX - size.width / 2).rounded(),
            y: min(area.midY - size.height / 2, area.maxY - size.height).rounded()
        )
    }
}
