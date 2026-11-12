import AppKit

/// The small floating window that holds one thumbnail card.
///
/// Like the selection overlay it is a non-activating panel: clicking its
/// buttons does not pull the user out of the app they are working in.
final class ThumbnailPanel: NSPanel {
    /// Above ordinary windows. Screenshots leave out Pashari's windows at
    /// this level (see `ScreenCapturer.ownWindowsToHide`).
    static let windowLevel: NSWindow.Level = .floating

    init(contentView: NSView) {
        super.init(
            contentRect: contentView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.contentView = contentView

        // Float above ordinary windows, on every Space.
        level = Self.windowLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // The window itself is invisible; only the rounded card inside shows,
        // and the shadow follows the card's shape.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
    }
}
