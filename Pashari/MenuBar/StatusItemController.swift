import AppKit
import KeyboardShortcuts

/// Owns the menu bar icon and the menu that drops down from it.
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let captureCoordinator: CaptureCoordinator
    private let settingsWindowController: SettingsWindowController

    init(captureCoordinator: CaptureCoordinator, settingsWindowController: SettingsWindowController) {
        self.captureCoordinator = captureCoordinator
        self.settingsWindowController = settingsWindowController
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
        menu.addItem(
            makeItem(String(localized: "Capture Area"), #selector(captureArea), shortcut: .captureArea)
        )
        menu.addItem(
            makeItem(String(localized: "Capture Window"), #selector(captureWindow), shortcut: .captureWindow)
        )
        menu.addItem(
            makeItem(
                String(localized: "Capture Fullscreen"),
                #selector(captureFullscreen),
                shortcut: .captureFullscreen
            )
        )

        menu.addItem(.separator())

        let settingsItem = makeItem(String(localized: "Settings…"), #selector(showSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)

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

    private func makeItem(
        _ title: String,
        _ action: Selector,
        shortcut: KeyboardShortcuts.Name? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        // Shows the global hotkey next to the title, and keeps it up to date
        // when the user changes it in Settings.
        item.setShortcut(for: shortcut)
        return item
    }

    // `@objc` exposes a method to the Objective-C runtime, which is how
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

    @objc private func showSettings() {
        settingsWindowController.show()
    }
}
