import AppKit
import KeyboardShortcuts

final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let captureCoordinator: CaptureCoordinator
    private let settingsWindowController: SettingsWindowController
    private var menu: NSMenu?

    init(captureCoordinator: CaptureCoordinator, settingsWindowController: SettingsWindowController) {
        self.captureCoordinator = captureCoordinator
        self.settingsWindowController = settingsWindowController
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        menu = makeMenu()
        showRecording(false)
        captureCoordinator.onRecordingChange = { [weak self] isRecording in
            self?.showRecording(isRecording)
        }
    }

    /// While recording, the icon is a stop button: a click stops at once,
    /// without the menu.
    private func showRecording(_ isRecording: Bool) {
        guard let button = statusItem.button else { return }
        if isRecording {
            statusItem.menu = nil
            button.image = NSImage(
                systemSymbolName: "stop.circle",
                accessibilityDescription: String(localized: "Stop Recording")
            )
            button.toolTip = String(localized: "Stop Recording")
            button.target = self
            button.action = #selector(stopRecording)
        } else {
            button.image = NSImage(
                systemSymbolName: "camera.viewfinder",
                accessibilityDescription: "Pashari"
            )
            button.toolTip = nil
            button.action = nil
            statusItem.menu = menu
        }
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
        menu.addItem(
            makeItem(
                String(localized: "Capture Scrolling Area"),
                #selector(captureScrollingArea),
                shortcut: .captureScrollingArea
            )
        )

        menu.addItem(.separator())

        menu.addItem(makeItem(String(localized: "Record Area"), #selector(recordArea), shortcut: .recordArea))
        menu.addItem(makeItem(String(localized: "Record Window"), #selector(recordWindow), shortcut: .recordWindow))
        menu.addItem(makeItem(
            String(localized: "Record Fullscreen"), #selector(recordFullscreen), shortcut: .recordFullscreen
        ))

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

    @objc private func captureScrollingArea() {
        captureCoordinator.captureScrollingArea()
    }

    @objc private func recordArea() {
        captureCoordinator.recordArea()
    }

    @objc private func recordWindow() {
        captureCoordinator.recordWindow()
    }

    @objc private func recordFullscreen() {
        captureCoordinator.recordFullscreen()
    }

    @objc private func stopRecording() {
        captureCoordinator.stopRecording()
    }

    @objc private func showSettings() {
        settingsWindowController.show()
    }
}
