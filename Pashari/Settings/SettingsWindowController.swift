import AppKit
import SwiftUI

final class SettingsWindowController {
    private var window: NSWindow?
    private let model = SettingsModel()
    private var naturalContentSize: CGSize?
    private let visibleFrameForWindow: (NSWindow) -> CGRect?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(visibleFrameForWindow: @escaping (NSWindow) -> CGRect? = { $0.screen?.visibleFrame }) {
        self.visibleFrameForWindow = visibleFrameForWindow
        let audioObserver = NotificationCenter.default.addObserver(
            forName: Preferences.recordingAudioDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.reloadRecordingAudio()
            }
        }
        observers.append(audioObserver)
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func show() {
        model.reload()
        let screen = NSScreen.underMouse ?? NSScreen.main
        if window == nil {
            let window = makeWindow(fitting: screen?.visibleFrame)
            if let screen {
                window.center(on: screen)
            } else {
                window.center()
            }
            self.window = window
        } else if let window, let screen {
            let naturalSize = resolvedNaturalContentSize()
            if !window.isVisible {
                let previousSize = window.frame.size
                window.setContentSize(Self.contentSize(for: naturalSize, fitting: screen.visibleFrame, in: window))
                let offScreen = !screen.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY))
                if offScreen || window.frame.size != previousSize {
                    window.center(on: screen)
                }
            } else {
                refitWindow(window, to: visibleFrameForWindow(window) ?? screen.visibleFrame)
            }
        }

        // A menu bar app is not the active app, so its window would open
        // behind everything else without this.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Creates the Settings window and attaches display-change observers so
    /// moving an open window onto a shorter display (or changing display
    /// resolution/Dock geometry) immediately clamps and enables scrolling.
    func makeWindow(fitting visibleFrame: CGRect?) -> NSWindow {
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
        let naturalSize = resolvedNaturalContentSize()
        window.setContentSize(Self.contentSize(for: naturalSize, fitting: visibleFrame, in: window))
        observeScreenChanges(for: window)
        self.window = window
        return window
    }

    private func observeScreenChanges(for window: NSWindow) {
        let handleScreenChange: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refitVisibleWindow()
            }
        }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main,
                using: handleScreenChange
            )
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main,
                using: handleScreenChange
            )
        )
    }

    private func resolvedNaturalContentSize() -> CGSize {
        if let naturalContentSize { return naturalContentSize }
        let measured = SettingsView.naturalContentSize(for: model)
        naturalContentSize = measured
        return measured
    }

    private func refitVisibleWindow() {
        guard let window, window.isVisible, let visibleFrame = visibleFrameForWindow(window) else {
            return
        }
        refitWindow(window, to: visibleFrame)
    }

    private func refitWindow(_ window: NSWindow, to visibleFrame: CGRect) {
        let naturalSize = resolvedNaturalContentSize()
        let adjusted = Self.fittedFrame(
            for: window.frame,
            naturalContentSize: naturalSize,
            in: visibleFrame,
            frameRect: { window.frameRect(forContentRect: $0) },
            contentRect: { window.contentRect(forFrameRect: $0) }
        )
        let sizeChanged = abs(adjusted.width - window.frame.width) > 0.5
            || abs(adjusted.height - window.frame.height) > 0.5
        let clipsVertically = window.frame.minY < visibleFrame.minY
            || window.frame.maxY > visibleFrame.maxY
        if sizeChanged || clipsVertically {
            window.setFrame(adjusted, display: true)
        }
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

    /// Computes an updated window frame for `visibleFrame`, resizing vertically
    /// between the clamped height and `naturalContentSize` while keeping the
    /// title bar anchored and both top and bottom inside `visibleFrame`.
    static func fittedFrame(
        for currentFrame: CGRect,
        naturalContentSize: CGSize,
        in visibleFrame: CGRect,
        frameRect: (CGRect) -> CGRect,
        contentRect: (CGRect) -> CGRect
    ) -> CGRect {
        let targetContentSize = contentSize(
            for: naturalContentSize,
            fitting: visibleFrame,
            frameRect: frameRect,
            contentRect: contentRect
        )
        let targetFrameSize = frameRect(CGRect(origin: .zero, size: targetContentSize)).size
        let anchoredY = currentFrame.maxY - targetFrameSize.height
        let clampedY = max(
            visibleFrame.minY,
            min(anchoredY, visibleFrame.maxY - targetFrameSize.height)
        ).rounded()
        return CGRect(
            x: currentFrame.minX,
            y: clampedY,
            width: targetFrameSize.width,
            height: targetFrameSize.height
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
