import AppKit

/// Conversions between the two coordinate systems macOS uses for the desktop.
///
/// - AppKit (`NSScreen`, `NSWindow`, `NSEvent.mouseLocation`): the origin is
///   the bottom-left corner of the primary display, and y grows upwards.
/// - Core Graphics and ScreenCaptureKit (`SCWindow.frame`): the origin is the
///   top-left corner of the primary display, and y grows downwards.
enum ScreenGeometry {
    /// Height of the primary display, the one with the menu bar. It is always
    /// the first entry in `NSScreen.screens`.
    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// Converts a rectangle from one system to the other. The same formula
    /// works in both directions.
    static func flipped(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
