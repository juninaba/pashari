import AppKit
import SwiftUI

final class SettingsWindowController {
    private var window: NSWindow?
    private let model = SettingsModel()
    private var naturalContentSize: CGSize?
    nonisolated(unsafe) private var audioObserver: NSObjectProtocol?

    init() {
        audioObserver = NotificationCenter.default.addObserver(
            forName: Preferences.recordingAudioDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.reloadRecordingAudio()
            }
        }
    }

    deinit {
        if let audioObserver {
            NotificationCenter.default.removeObserver(audioObserver)
        }
    }

    func show() {
        model.reload()
        let screen = NSScreen.underMouse ?? NSScreen.main
        if window == nil {
            let hostingController = NSHostingController(rootView: SettingsView(model: model))
            // Keep AppKit in control of the window height so clamping to a
            // shorter display is not undone by SwiftUI's ScrollView ideal size.
            hostingController.sizingOptions = []
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
            // view out, so the window is still empty here. Measure the full
            // unclipped layout first, then clamp to the target display's
            // visible area so short displays (e.g. 1280x800) scroll instead of
            // pushing the bottom rows off screen.
            let naturalSize = SettingsView.naturalContentSize(for: model)
            naturalContentSize = naturalSize
            window.setContentSize(Self.contentSize(for: naturalSize, fitting: screen?.visibleFrame, in: window))
            if let screen {
                window.center(on: screen)
            } else {
                window.center()
            }
            self.window = window
        } else if let window, let screen {
            let naturalSize = naturalContentSize ?? SettingsView.naturalContentSize(for: model)
            naturalContentSize = naturalSize
            if !window.isVisible {
                let previousSize = window.frame.size
                window.setContentSize(Self.contentSize(for: naturalSize, fitting: screen.visibleFrame, in: window))
                let offScreen = !screen.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY))
                if offScreen || window.frame.size != previousSize {
                    window.center(on: screen)
                }
            } else {
                let currentScreen = window.screen ?? screen
                if window.frame.height > currentScreen.visibleFrame.height {
                    window.setContentSize(Self.contentSize(for: naturalSize, fitting: currentScreen.visibleFrame, in: window))
                    window.center(on: currentScreen)
                }
            }
        }

        // A menu bar app is not the active app, so its window would open
        // behind everything else without this.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private static func contentSize(
        for naturalSize: CGSize,
        fitting visibleFrame: CGRect?,
        in window: NSWindow
    ) -> CGSize {
        contentSize(
            for: naturalSize,
            fitting: visibleFrame,
            frameRect: { window.frameRect(forContentRect: $0) },
            contentRect: { window.contentRect(forFrameRect: $0) }
        )
    }

    /// Fits `naturalSize` inside `visibleFrame`, keeping the full unclipped
    /// height when it fits and clamping vertically (accounting for the title
    /// bar) when the display is shorter.
    static func contentSize(
        for naturalSize: CGSize,
        fitting visibleFrame: CGRect?,
        frameRect: (CGRect) -> CGRect,
        contentRect: (CGRect) -> CGRect
    ) -> CGSize {
        guard let visibleFrame, visibleFrame.height > 0 else {
            return naturalSize
        }
        let naturalFrame = frameRect(CGRect(origin: .zero, size: naturalSize))
        guard naturalFrame.height > visibleFrame.height else {
            return naturalSize
        }
        let clampedFrame = CGRect(
            origin: .zero,
            size: CGSize(width: naturalFrame.width, height: floor(visibleFrame.height))
        )
        let clampedContent = contentRect(clampedFrame)
        return CGSize(
            width: naturalSize.width,
            height: max(1, floor(clampedContent.height))
        )
    }
}
