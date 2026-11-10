import AppKit
import SwiftUI

/// Opens the Settings window, creating it the first time.
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            // `NSHostingController` is the bridge that puts a SwiftUI view
            // inside an AppKit window.
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = String(localized: "Pashari Settings")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }

        // A menu bar app is not the active app, so its window would open
        // behind everything else without this.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
