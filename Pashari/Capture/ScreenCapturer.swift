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

    /// Pashari's own windows that must not appear in a screenshot.
    ///
    /// The menu is still fading out when the capture starts, and later the
    /// floating thumbnail will be on screen too. The menu bar icon itself is
    /// kept: without it the screenshot would have a hole in the menu bar.
    private static func ownWindowsToHide(in content: SCShareableContent) -> [SCWindow] {
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let menuBarIconLayer = Int(CGWindowLevelForKey(.statusWindow))
        return content.windows.filter { window in
            window.owningApplication?.processID == ownProcessID
                && window.windowLayer != menuBarIconLayer
        }
    }
}
