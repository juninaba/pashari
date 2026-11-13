import AppKit
import ScreenCaptureKit

/// Lets the user point at a window and click it.
final class WindowSelectionSession {
    private var windows: [SCWindow] = []
    /// Frames of `windows` in AppKit screen coordinates, in the same order.
    private var frames: [CGRect] = []
    private var highlightedIndex: Int?

    private var panels: [OverlayPanel] = []
    private var views: [WindowSelectionView] = []
    private var continuation: CheckedContinuation<Int?, Never>?
    private var spaceObserver: SpaceChangeObserver?
    /// Counts Space changes, so a window list that arrives late, after the
    /// user has already moved on to yet another Space, can be told apart.
    private var spaceChanges = 0

    /// `windows` must be ordered front to back. Returns the window the user
    /// clicked, or nil when they cancelled.
    func run(with windows: [SCWindow]) async -> SCWindow? {
        setWindows(windows)

        // The continuation carries the window's position in `windows` rather
        // than the window itself: `SCWindow` is not marked as safe to hand
        // between threads (`Sendable`), while an `Int` always is.
        let selectedIndex = await withCheckedContinuation { continuation in
            self.continuation = continuation
            show()
        }
        // `self.windows`, not the argument: the list is replaced when the
        // user moves to another Space.
        return selectedIndex.map { self.windows[$0] }
    }

    private func setWindows(_ windows: [SCWindow]) {
        self.windows = windows
        let primaryScreenHeight = ScreenGeometry.primaryScreenHeight
        frames = windows.map {
            ScreenGeometry.flipped($0.frame, primaryScreenHeight: primaryScreenHeight)
        }
    }

    private func show() {
        for screen in NSScreen.screens {
            let panel = OverlayPanel(screen: screen)
            let view = WindowSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onPointerMove = { [weak self] in self?.updateHighlight() }
            view.onClick = { [weak self] in self?.click() }
            panel.onCancel = { [weak self] in self?.finish(with: nil) }
            view.onCancel = panel.onCancel

            panel.contentView = view
            panel.makeFirstResponder(view)
            panel.orderFrontRegardless()
            panels.append(panel)
            views.append(view)
        }

        OverlayPanel.focus(panels)
        updateHighlight()
        spaceObserver = SpaceChangeObserver { [weak self] in
            self?.spaceDidChange()
        }
        Log.selection.info("Window overlay shown on \(self.panels.count) screen(s), \(self.windows.count) window(s) to pick from")
    }

    /// The windows found at the start belong to the Space the user left, so
    /// they are looked up again.
    private func spaceDidChange() {
        // A notification can still arrive just after the user finished.
        guard continuation != nil else { return }

        // Pick nothing until the new list arrives. A click in the meantime
        // would otherwise capture a window of the Space the user left.
        setWindows([])
        updateHighlight()
        spaceChanges += 1
        let change = spaceChanges

        Task {
            let windows = (try? await ScreenCapturer.selectableWindows()) ?? []
            // Drop the list if the user finished, or moved on to yet another
            // Space, while it was loading.
            guard continuation != nil, change == spaceChanges else { return }
            setWindows(windows)
            updateHighlight()
            // The app on the new Space has become active and taken the
            // keyboard. Take it back, so Escape still cancels.
            OverlayPanel.focus(panels)
            Log.selection.info("Moved to another Space: \(windows.count) window(s) to pick from")
        }
    }

    /// Finds the frontmost window under the pointer and shows it on every
    /// screen it reaches into.
    private func updateHighlight() {
        highlightedIndex = Self.indexOfFrontmostFrame(at: NSEvent.mouseLocation, in: frames)
        let highlight = highlightedIndex.map { frames[$0] }

        for (panel, view) in zip(panels, views) {
            // Screen coordinates to this view's coordinates: the view's
            // origin is the panel's bottom-left corner.
            view.highlightFrame = highlight?.offsetBy(
                dx: -panel.frame.minX,
                dy: -panel.frame.minY
            )
        }
    }

    private func click() {
        // A click on the bare desktop picks nothing; keep waiting.
        guard let highlightedIndex else {
            Log.selection.info("Clicked outside every window: still waiting")
            return
        }
        finish(with: highlightedIndex)
    }

    private func finish(with result: Int?) {
        guard let continuation else { return }
        self.continuation = nil
        Log.selection.info("Window selection finished: \(result == nil ? "cancelled" : "selected", privacy: .public)")

        spaceObserver?.stop()
        spaceObserver = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
        NSCursor.arrow.set()
        continuation.resume(returning: result)
    }

    /// `frames` is ordered front to back, so the first hit is the window the
    /// user actually sees at that point.
    static func indexOfFrontmostFrame(at point: CGPoint, in frames: [CGRect]) -> Int? {
        frames.firstIndex { NSMouseInRect(point, $0, false) }
    }
}
