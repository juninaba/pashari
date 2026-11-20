import AppKit
import Testing

@testable import Pashari

/// An opaque panel of Pashari's at the level of its overlays.
@MainActor
enum Cover {
    static func show(over frame: CGRect) async throws -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = OverlayPanel.windowLevel
        panel.backgroundColor = .systemRed
        panel.isOpaque = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        try await waitUntilOnScreen(panel)
        return panel
    }
}

/// A window comes on screen a moment after it is ordered front, once the
/// main thread is free to finish showing it.
@MainActor
func waitUntilOnScreen(_ window: NSWindow) async throws {
    let id = CGWindowID(window.windowNumber)
    for _ in 0..<100 {
        let onScreen = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[CFString: Any]] ?? []
        if onScreen.contains(where: { $0[kCGWindowNumber] as? CGWindowID == id }) {
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("The test window did not come on screen")
}
