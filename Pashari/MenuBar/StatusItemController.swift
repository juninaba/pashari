import AppKit

/// Owns the menu bar icon and the menu that drops down from it.
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let captureCoordinator: CaptureCoordinator

    init(captureCoordinator: CaptureCoordinator) {
        self.captureCoordinator = captureCoordinator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        // Placeholder glyph from SF Symbols until Pashari has its own icon.
        // Symbol images are "template" images: the system tints them to match
        // a light or dark menu bar.
        statusItem.button?.image = NSImage(
            systemSymbolName: "camera.viewfinder",
            accessibilityDescription: "Pashari"
        )
        statusItem.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        // AppKit menus use "target-action": when the item is chosen, AppKit
        // calls the method named by `action` on the object in `target`.
        let captureItems = [
            NSMenuItem(
                title: String(localized: "Capture Area"),
                action: #selector(captureArea),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: String(localized: "Capture Window"),
                action: #selector(captureWindow),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: String(localized: "Capture Fullscreen"),
                action: #selector(captureFullscreen),
                keyEquivalent: ""
            ),
        ]
        for item in captureItems {
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // No target: AppKit sends `terminate:` up the responder chain, where
        // NSApplication handles it.
        menu.addItem(
            withTitle: String(localized: "Quit Pashari"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        return menu
    }

    // `@objc` exposes the method to the Objective-C runtime, which is how
    // `#selector` finds it by name.
    @objc private func captureArea() {
        captureCoordinator.captureArea()
    }

    @objc private func captureWindow() {
        captureCoordinator.captureWindow()
    }

    @objc private func captureFullscreen() {
        captureCoordinator.captureFullscreen()
    }
}
