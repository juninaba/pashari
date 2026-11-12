import AppKit
import ScreenCaptureKit

/// A still image of one whole screen, used as the backdrop for area selection.
struct FrozenScreen {
    let screen: NSScreen
    let screenshot: Screenshot
}

/// Takes still images of the screen with ScreenCaptureKit.
enum ScreenCapturer {
    /// Captures everything visible on one display.
    static func captureDisplay(_ screen: NSScreen) async throws -> Screenshot {
        let content = try await shareableContent()
        return try await capture(screen, content: content)
    }

    /// Captures every connected display.
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

    /// Asks the system what can be captured right now: displays and windows.
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

        // `contentRect` is in points and `pointPixelScale` converts to pixels,
        // so the output keeps the display's full (Retina) resolution.
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

    /// Pashari's own windows that must not appear in a screenshot: the menu,
    /// which is still fading out when the capture starts, the floating
    /// thumbnails and the selection overlays. They all sit above the layer
    /// of ordinary windows.
    ///
    /// Ordinary windows, such as Settings and the editor, stay in the
    /// picture like any other app's, as they do in window mode. So does the
    /// menu bar icon: without it the screenshot would have a hole in the
    /// menu bar.
    static func ownWindowsToHide(in content: SCShareableContent) -> [SCWindow] {
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let menuBarIconLayer = Int(CGWindowLevelForKey(.statusWindow))
        return content.windows.filter { window in
            window.owningApplication?.processID == ownProcessID
                && window.windowLayer != 0
                && window.windowLayer != menuBarIconLayer
        }
    }
}
