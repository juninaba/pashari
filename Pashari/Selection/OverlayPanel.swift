import AppKit

/// A borderless window that covers one whole screen while the user picks what
/// to capture.
///
/// It is an `NSPanel` with `.nonactivatingPanel`, which lets it receive mouse
/// and keyboard input without making Pashari the active app. Whatever app the
/// user was working in stays active.
final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)

        // Above the menu bar, the Dock and any open menus.
        level = .screenSaver
        // Show on whichever Space is current, including full-screen apps.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none

        // Panels hide themselves when their app is not active. Pashari never
        // is, so that default would make the overlay vanish immediately.
        hidesOnDeactivate = false
        // Windows created in code are owned by Swift references, not by AppKit.
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
    }

    // Borderless windows refuse keyboard focus by default. The overlay needs
    // it to hear the Escape key.
    override var canBecomeKey: Bool { true }
}
