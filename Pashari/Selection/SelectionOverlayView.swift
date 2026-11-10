import AppKit
import Carbon.HIToolbox

/// Shared behaviour of the views that fill an `OverlayPanel`: keyboard focus,
/// cancelling with Escape or a right click, and mouse tracking that works
/// while Pashari is not the active app.
class SelectionOverlayView: NSView {
    /// Called when the user backs out without choosing anything.
    var onCancel: (() -> Void)?

    /// The pointer shown while it is over this view.
    var cursor: NSCursor { .arrow }

    // Take keyboard input, and react to the very first click even though the
    // panel was not focused before it.
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // `.activeAlways`: deliver these events even though Pashari is not the
        // active app.
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .inVisibleRect, .mouseMoved, .cursorUpdate],
                owner: self
            )
        )
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }

    override func mouseMoved(with event: NSEvent) {
        cursor.set()
    }
}
