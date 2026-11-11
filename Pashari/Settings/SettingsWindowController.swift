import AppKit
import SwiftUI

/// Opens the Settings window, creating it the first time.
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            // `NSHostingController` is the bridge that puts a SwiftUI view
            // inside an AppKit window.
            let hostingController = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hostingController)
            window.title = String(localized: "Pashari Settings")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // SwiftUI works out the view's size only when it first lays the
            // view out, so the window is still empty here. Size it first:
            // centering an empty window puts its corner in the middle of the
            // screen, and the settings then grow up and to the right of it.
            window.setContentSize(hostingController.view.fittingSize)
            window.center()
            self.window = window
        }

        // A menu bar app is not the active app, so its window would open
        // behind everything else without this.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
