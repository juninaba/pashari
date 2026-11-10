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

    /// `windows` must be ordered front to back. Returns the window the user
    /// clicked, or nil when they cancelled.
    func run(with windows: [SCWindow]) async -> SCWindow? {
        self.windows = windows
        let primaryScreenHeight = ScreenGeometry.primaryScreenHeight
        frames = windows.map {
            ScreenGeometry.flipped($0.frame, primaryScreenHeight: primaryScreenHeight)
        }

        // The continuation carries the window's position in `windows` rather
        // than the window itself: `SCWindow` is not marked as safe to hand
        // between threads (`Sendable`), while an `Int` always is.
        let selectedIndex = await withCheckedContinuation { continuation in
            self.continuation = continuation
            show()
        }
        return selectedIndex.map { windows[$0] }
    }

    private func show() {
        for screen in NSScreen.screens {
            let panel = OverlayPanel(screen: screen)
            let view = WindowSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onPointerMove = { [weak self] in self?.updateHighlight() }
            view.onClick = { [weak self] in self?.click() }
            view.onCancel = { [weak self] in self?.finish(with: nil) }

            panel.contentView = view
            panel.makeFirstResponder(view)
            panel.orderFrontRegardless()
            panels.append(panel)
            views.append(view)
        }

        let pointer = NSEvent.mouseLocation
        let keyPanel = panels.first { NSMouseInRect(pointer, $0.frame, false) } ?? panels.first
        keyPanel?.makeKey()
        updateHighlight()
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
        guard let highlightedIndex else { return }
        finish(with: highlightedIndex)
    }

    private func finish(with result: Int?) {
        guard let continuation else { return }
        self.continuation = nil

        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
        continuation.resume(returning: result)
    }

    /// `frames` is ordered front to back, so the first hit is the window the
    /// user actually sees at that point.
    static func indexOfFrontmostFrame(at point: CGPoint, in frames: [CGRect]) -> Int? {
        frames.firstIndex { NSMouseInRect(point, $0, false) }
    }
}
