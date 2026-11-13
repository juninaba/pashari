import AppKit

/// Shows the frozen screens, waits for the user to drag out a rectangle, and
/// hands back the selected part.
final class AreaSelectionSession {
    /// The overlay covering one screen.
    private struct Overlay {
        let panel: OverlayPanel
        /// Shows the frozen screenshot.
        let backdrop: NSView
        let selectionView: AreaSelectionView
        var frozen: FrozenScreen
    }

    private var overlays: [Overlay] = []
    private var continuation: CheckedContinuation<Screenshot?, Never>?
    private var spaceObserver: SpaceChangeObserver?
    /// Counts Space changes, so screenshots that arrive late, after the user
    /// has already moved on to yet another Space, can be told apart.
    private var spaceChanges = 0
    /// True from a Space change until the screens are captured again.
    private var isCatchingUp = false

    /// Returns the selected part of the screen, or nil when the user cancelled.
    func run(with frozenScreens: [FrozenScreen]) async -> Screenshot? {
        // A dialog may have opened while the screen images were being captured.
        guard NSApp.modalWindow == nil else { return nil }
        // The overlay reports its result through callbacks. A continuation
        // turns that into something the caller can `await`.
        return await withCheckedContinuation { continuation in
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
            let index = overlays.count
            selectionView.onSelect = { [weak self] rect in
                self?.select(rect, onScreenAt: index)
            }
            selectionView.onCancel = { [weak self] in
                self?.finish(with: nil)
            }
            backdrop.addSubview(selectionView)

            panel.contentView = backdrop
            panel.makeFirstResponder(selectionView)
            panel.orderFrontRegardless()
            overlays.append(
                Overlay(panel: panel, backdrop: backdrop, selectionView: selectionView, frozen: frozen)
            )
        }

        OverlayPanel.focus(overlays.map(\.panel))
        NSCursor.crosshair.set()
        spaceObserver = SpaceChangeObserver { [weak self] in
            self?.spaceDidChange()
        }
        Log.selection.info("Area overlay shown on \(self.overlays.count) screen(s)")
    }

    private func select(_ rect: CGRect, onScreenAt index: Int) {
        // Right after a Space change the frozen screenshot is still the one
        // of the Space the user left. Let them drag again instead.
        guard !isCatchingUp else {
            overlays[index].selectionView.clearSelection()
            return
        }
        finish(with: overlays[index].frozen.screenshot.cropped(to: rect))
    }

    /// The frozen screenshots show the Space the user left, so the screens
    /// are captured again.
    private func spaceDidChange() {
        // A notification can still arrive just after the user finished.
        guard continuation != nil else { return }

        // Until the new screenshots arrive, show the screen as it is now,
        // under the dimming, and let no selection through.
        isCatchingUp = true
        for overlay in overlays {
            overlay.backdrop.layer?.contents = nil
        }
        spaceChanges += 1
        let change = spaceChanges

        Task {
            // Pashari's own windows, this overlay among them, are left out of
            // the capture.
            let frozenScreens = (try? await ScreenCapturer.captureAllDisplays()) ?? []
            // Drop them if the user finished, or moved on to yet another
            // Space, while they were being taken.
            guard continuation != nil, change == spaceChanges else { return }
            guard replaceFrozenScreens(with: frozenScreens) else {
                Log.selection.error("The screens could not be captured again after a Space change")
                finish(with: nil)
                return
            }
            isCatchingUp = false
            // The app on the new Space has become active and taken the
            // keyboard. Take it back, so Escape still cancels.
            OverlayPanel.focus(overlays.map(\.panel))
            Log.selection.info("Moved to another Space: screens captured again")
        }
    }

    /// Puts each screen's new screenshot in place. Returns false when a
    /// screen has none.
    private func replaceFrozenScreens(with frozenScreens: [FrozenScreen]) -> Bool {
        for index in overlays.indices {
            let displayID = overlays[index].frozen.screen.displayID
            guard let frozen = frozenScreens.first(where: { $0.screen.displayID == displayID }) else {
                return false
            }
            overlays[index].frozen = frozen
            overlays[index].backdrop.layer?.contents = frozen.screenshot.image
        }
        return true
    }

    private func finish(with result: Screenshot?) {
        // A continuation must be resumed exactly once. Clearing it first
        // makes a second call (say, Escape during mouse-up) a no-op.
        guard let continuation else { return }
        self.continuation = nil
        Log.selection.info("Area selection finished: \(result == nil ? "cancelled" : "selected", privacy: .public)")

        spaceObserver?.stop()
        spaceObserver = nil
        overlays.forEach { $0.panel.orderOut(nil) }
        overlays.removeAll()
        NSCursor.arrow.set()
        continuation.resume(returning: result)
    }
}
