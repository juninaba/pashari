import AppKit

/// Owns the menu bar icon and the menu that drops down from it.
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem

    override init() {
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

        // No target: AppKit sends `terminate:` up the responder chain, where
        // NSApplication handles it.
        menu.addItem(
            withTitle: String(localized: "Quit Pashari"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        return menu
    }
}
