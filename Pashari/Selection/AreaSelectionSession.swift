import AppKit

/// Shows the frozen screens, waits for the user to drag out a rectangle, and
/// hands back the selected part.
final class AreaSelectionSession {
    private var panels: [OverlayPanel] = []
    private var continuation: CheckedContinuation<Screenshot?, Never>?

    /// Returns the selected part of the screen, or nil when the user cancelled.
    func run(with frozenScreens: [FrozenScreen]) async -> Screenshot? {
        // The overlay reports its result through callbacks. A continuation
        // turns that into something the caller can `await`.
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            show(frozenScreens)
        }
    }

    private func show(_ frozenScreens: [FrozenScreen]) {
        for frozen in frozenScreens {
            let panel = OverlayPanel(screen: frozen.screen)
            let bounds = CGRect(origin: .zero, size: frozen.screen.frame.size)

            // Bottom layer: the frozen screenshot, drawn by Core Animation.
            // Setting it as layer contents means it is never redrawn while
            // the selection changes on top of it.
            let backdrop = NSView(frame: bounds)
            backdrop.wantsLayer = true
            backdrop.layer?.contents = frozen.screenshot.image
            backdrop.layer?.contentsGravity = .resize

            // Top layer: dimming and the selection rectangle.
            let selectionView = AreaSelectionView(frame: bounds, scale: frozen.screenshot.scale)
            selectionView.autoresizingMask = [.width, .height]
            selectionView.onSelect = { [weak self] rect in
                self?.finish(with: frozen.screenshot.cropped(to: rect))
            }
            selectionView.onCancel = { [weak self] in
                self?.finish(with: nil)
            }
            backdrop.addSubview(selectionView)

            panel.contentView = backdrop
            panel.makeFirstResponder(selectionView)
            panel.orderFrontRegardless()
            panels.append(panel)
        }

        // Give keyboard focus to the overlay under the pointer, so Escape works.
        let pointer = NSEvent.mouseLocation
        let keyPanel = panels.first { NSMouseInRect(pointer, $0.frame, false) } ?? panels.first
        keyPanel?.makeKey()
        NSCursor.crosshair.set()
    }

    private func finish(with result: Screenshot?) {
        // A continuation must be resumed exactly once. Clearing it first
        // makes a second call (say, Escape during mouse-up) a no-op.
        guard let continuation else { return }
        self.continuation = nil

        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        NSCursor.arrow.set()
        continuation.resume(returning: result)
    }
}
