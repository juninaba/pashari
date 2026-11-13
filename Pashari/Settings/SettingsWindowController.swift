import AppKit
import SwiftUI

final class SettingsWindowController {
    private var window: NSWindow?
    private let model = SettingsModel()

    func show() {
        model.reload()
        let screen = NSScreen.underMouse ?? NSScreen.main
        if window == nil {
            let hostingController = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: hostingController)
            window.title = String(localized: "Pashari Settings")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // SwiftUI works out the view's size only when it first lays the
            // view out, so the window is still empty here. Size it first:
            // centering an empty window puts its corner in the middle of the
            // screen, and the settings then grow up and to the right of it.
            window.setContentSize(hostingController.view.fittingSize)
            if let screen {
                window.center(on: screen)
            } else {
                window.center()
            }
            self.window = window
        } else if let window, let screen, !window.isVisible,
                  !screen.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)) {
            window.center(on: screen)
        }

        // A menu bar app is not the active app, so its window would open
        // behind everything else without this.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
