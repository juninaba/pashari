import AppKit
import ScreenCaptureKit

/// Takes still images of the screen with ScreenCaptureKit.
enum ScreenCapturer {
    /// Captures everything visible on one display.
    static func captureDisplay(_ screen: NSScreen) async throws -> Screenshot {
        // Ask the system what can be captured right now: displays and windows.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

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
