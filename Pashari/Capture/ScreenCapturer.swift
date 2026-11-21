import AppKit
import ScreenCaptureKit

struct FrozenScreen {
    let screen: NSScreen
    let screenshot: Screenshot
}

enum ScreenCapturer {
    static func captureDisplay(_ screen: NSScreen) async throws -> Screenshot {
        let content = try await shareableContent()
        return try await capture(screen, content: content)
    }

    static func captureAllDisplays() async throws -> [FrozenScreen] {
        let content = try await shareableContent()
        var frozenScreens: [FrozenScreen] = []
        for screen in NSScreen.screens {
            let screenshot = try await capture(screen, content: content)
            frozenScreens.append(FrozenScreen(screen: screen, screenshot: screenshot))
        }
        return frozenScreens
    }

    /// The windows the user can pick in window mode, ordered front to back.
    /// Pashari's own windows, such as Settings and the editor, are among
    /// them like any other app's.
    static func selectableWindows() async throws -> [SCWindow] {
        let content = try await shareableContent()

        // ScreenCaptureKit does not promise any order, but the older window
        // list API returns on-screen windows front to back. Use its order.
        let stackingOrder = windowIDsFrontToBack()
        let position = Dictionary(
            stackingOrder.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return content.windows
            .filter { window in
                // Layer 0 holds ordinary app windows. The menu bar, the Dock,
                // desktop icons and so on live on other layers, and so do
                // Pashari's thumbnails and selection overlays.
                window.windowLayer == 0
                    && window.isOnScreen
                    && window.owningApplication != nil
                    && window.frame.width >= minimumWindowSide
                    && window.frame.height >= minimumWindowSide
                    && position[window.windowID] != nil
            }
            .sorted { position[$0.windowID]! < position[$1.windowID]! }
    }

    /// Captures one window on its own, without whatever is in front of or
    /// behind it. The corners outside the window's rounded shape stay
    /// transparent.
    static func captureWindow(_ window: SCWindow) async throws -> Screenshot {
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.width = Int((filter.contentRect.width * scale).rounded())
        configuration.height = Int((filter.contentRect.height * scale).rounded())
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return Screenshot(image: image, scale: scale, capturedAt: Date())
    }

    /// Windows smaller than this are helpers (badges, invisible trackers),
    /// not something a person would point at.
    private static let minimumWindowSide: CGFloat = 40

    private static func windowIDsFrontToBack() -> [CGWindowID] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard
            let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]]
        else {
            return []
        }
        return list.compactMap { $0[kCGWindowNumber] as? CGWindowID }
    }

    private static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    private static func capture(
        _ screen: NSScreen,
        content: SCShareableContent
    ) async throws -> Screenshot {
        guard
            let displayID = screen.displayID,
            let display = content.displays.first(where: { $0.displayID == displayID })
        else {
            throw CaptureError.displayNotFound
        }

        let filter = SCContentFilter(
            display: display,
            excludingWindows: ownWindowsToHide(in: content)
        )

        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.width = Int((filter.contentRect.width * scale).rounded())
        configuration.height = Int((filter.contentRect.height * scale).rounded())
        configuration.captureResolution = .best
        configuration.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return Screenshot(image: image, scale: scale, capturedAt: Date())
    }

    /// Pashari's own windows that must not appear in a screenshot: the
    /// floating thumbnails, the selection overlays, and the menu, which is
    /// still fading out when the capture starts. They are told apart by
    /// their window levels.
    ///
    /// Everything else of Pashari's stays in the picture like any other
    /// app's windows: Settings, the editor, alerts, the folder picker, and
    /// the menu bar icon (without it the screenshot would have a hole in the
    /// menu bar).
    static func ownWindowsToHide(in content: SCShareableContent) -> [SCWindow] {
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let levelsToHide: Set<Int> = [
            ThumbnailPanel.windowLevel.rawValue,
            OverlayPanel.windowLevel.rawValue,
            NSWindow.Level.popUpMenu.rawValue,
        ]
        return content.windows.filter { window in
            window.owningApplication?.processID == ownProcessID
                && levelsToHide.contains(window.windowLayer)
        }
    }

    /// What is on screen, for a recording that must leave out Pashari's
    /// overlays and bars. They were only just put on screen and may not be
    /// listed yet, which does not matter as long as Pashari itself is: the
    /// recording then leaves out all its windows but those a screenshot
    /// shows (see `recordingFilter`). Pashari is listed once any of its
    /// windows is, such as its menu bar icon.
    static func shareableContentListingPashari() async throws -> SCShareableContent {
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        var content = try await shareableContent()
        var attempts = 1
        while !content.applications.contains(where: { $0.processID == ownProcessID }), attempts < 10 {
            try await Task.sleep(for: .milliseconds(30))
            content = try await shareableContent()
            attempts += 1
        }
        return content
    }

    /// What to record of `display` so that the recording, like a
    /// screenshot, leaves out the windows of Pashari's that
    /// `ownWindowsToHide` picks, and also any that Pashari puts on screen
    /// later: those are not in `content` yet. A window just put on screen
    /// shows up in the list only a moment later.
    ///
    /// So it leaves out all of Pashari, except for the windows a
    /// screenshot would show. Only if Pashari itself is not listed, which
    /// takes a window of its own on screen, are the windows to hide left
    /// out one by one.
    static func recordingFilter(of display: SCDisplay, in content: SCShareableContent) -> SCContentFilter {
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let hidden = ownWindowsToHide(in: content)
        guard let pashari = content.applications.first(where: { $0.processID == ownProcessID }) else {
            return SCContentFilter(display: display, excludingWindows: hidden)
        }
        let hiddenIDs = Set(hidden.map(\.windowID))
        let shown = content.windows.filter { window in
            window.owningApplication?.processID == ownProcessID && !hiddenIDs.contains(window.windowID)
        }
        return SCContentFilter(display: display, excludingApplications: [pashari], exceptingWindows: shown)
    }
}
