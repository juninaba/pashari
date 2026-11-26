import AppKit
import SwiftUI

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = SettingsModel()

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidChangeScreen(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    func show() {
        model.reload()
        let screen = NSScreen.underMouse ?? NSScreen.main
        if window == nil {
            let hostingController = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: hostingController)
            window.title = String(localized: "Pashari Settings")
            window.styleMask = [.titled, .closable]
            // As in the editor, the title bar takes the header's colour so
            // that the two read as one. The header shows the title next to
            // the app's icon; the window keeps it for the Window menu and
            // Mission Control.
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = EditorStyle.header
            window.isReleasedWhenClosed = false
            // SwiftUI works out the view's size only when it first lays the
            // view out, so the window is still empty here. Size it first:
            // centering an empty window puts its corner in the middle of the
            // screen, and the settings then grow up and to the right of it.
            Self.fit(window, in: screen?.visibleFrame)
            if let screen {
                window.center(on: screen)
            } else {
                window.center()
            }
            self.window = window
            window.delegate = self
        } else if let window {
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            let movesToScreen = !window.isVisible && screen?.frame.contains(center) == false
            let targetScreen = movesToScreen ? screen : window.screen ?? screen
            Self.fit(window, in: targetScreen?.visibleFrame)
            if movesToScreen, let screen {
                window.center(on: screen)
            }
        }

        // A menu bar app is not the active app, so its window would open
        // behind everything else without this.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window, window.isVisible, let screen = window.screen else { return }
        Self.fit(window, in: screen.visibleFrame)
    }

    static func fit(_ window: NSWindow, in visibleFrame: CGRect?) {
        guard let contentView = window.contentView else { return }
        let originalFrame = window.frame
        var size = contentView.fittingSize
        if let visibleFrame {
            size.height = min(size.height, window.contentRect(forFrameRect: visibleFrame).height)
        }
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        frame.origin = CGPoint(x: originalFrame.minX, y: originalFrame.maxY - frame.height)
        if let visibleFrame {
            frame.origin.y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height)
        }
        if frame != window.frame {
            window.setFrame(frame, display: window.isVisible)
        }
    }
}
