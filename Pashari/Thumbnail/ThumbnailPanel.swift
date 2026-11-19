import AppKit

/// The window for all the thumbnails on one display. Like the selection
/// overlay it is a non-activating panel: clicking its buttons does not pull
/// the user out of the app they are working in.
final class ThumbnailPanel: NSPanel {
    /// Above ordinary windows. Screenshots leave out Pashari's windows at
    /// this level (see `ScreenCapturer.ownWindowsToHide`).
    static let windowLevel: NSWindow.Level = .floating

    let stackView = ThumbnailStackView()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        contentView = stackView

        level = Self.windowLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // The window itself is invisible. Clicks on its see-through parts
        // go to the windows underneath. The cards draw their own shadows,
        // which move and turn with them.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
    }
}
