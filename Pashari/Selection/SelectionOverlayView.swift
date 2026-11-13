import AppKit
import Carbon.HIToolbox

class SelectionOverlayView: NSView {
    var onCancel: (() -> Void)?

    var cursor: NSCursor { .arrow }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            Log.selection.info("Cancelled with Escape")
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        Log.selection.info("Cancelled with a right click")
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
