import AppKit

extension NSScreen {
    /// The Core Graphics ID of this screen. ScreenCaptureKit identifies
    /// displays by this number, while AppKit hands out `NSScreen` objects.
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// The screen the mouse pointer is on.
    static var underMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(location, $0.frame, false) }
    }
}
