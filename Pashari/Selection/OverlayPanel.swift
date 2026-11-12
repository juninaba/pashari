import AppKit

/// A borderless window that covers one whole screen while the user picks what
/// to capture.
///
/// It is an `NSPanel` with `.nonactivatingPanel`, which lets it receive mouse
/// and keyboard input without making Pashari the active app. Whatever app the
/// user was working in stays active.
final class OverlayPanel: NSPanel {
    /// Above the menu bar, the Dock and any open menus. Screenshots leave out
    /// Pashari's windows at this level (see `ScreenCapturer.ownWindowsToHide`).
    static let windowLevel: NSWindow.Level = .screenSaver

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)

        level = Self.windowLevel
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
        // Take every click, even on parts of the overlay that are fully
        // transparent. Unless this is set explicitly, macOS hands clicks on
        // such parts to the window underneath. Window mode leaves the
        // highlighted window clear, so a click on it went to that window's
        // app, which then took the keyboard too, and Escape stopped working.
        ignoresMouseEvents = false
    }

    // Borderless windows refuse keyboard focus by default. The overlay needs
    // it to hear the Escape key.
    override var canBecomeKey: Bool { true }

    /// Gives keyboard focus to whichever of `panels` is under the pointer
    /// (or else the first), so that Escape reaches the overlay.
    static func focus(_ panels: [OverlayPanel]) {
        let pointer = NSEvent.mouseLocation
        let panel = panels.first { NSMouseInRect(pointer, $0.frame, false) } ?? panels.first
        panel?.makeKey()
    }
}
