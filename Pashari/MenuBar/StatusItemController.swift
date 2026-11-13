import AppKit
import KeyboardShortcuts

final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let captureCoordinator: CaptureCoordinator
    private let settingsWindowController: SettingsWindowController

    init(captureCoordinator: CaptureCoordinator, settingsWindowController: SettingsWindowController) {
        self.captureCoordinator = captureCoordinator
        self.settingsWindowController = settingsWindowController
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "camera.viewfinder",
            accessibilityDescription: "Pashari"
        )
        statusItem.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

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
        item.setShortcut(for: shortcut)
        return item
    }

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
