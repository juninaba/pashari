import AppKit
import ScreenCaptureKit
import Testing

@testable import Pashari

/// These open real windows and ask ScreenCaptureKit about them, so they run
/// only where Pashari has the Screen Recording permission.
@MainActor
@Suite(.enabled(if: CGPreflightScreenCaptureAccess(), "needs the Screen Recording permission"))
struct ScreenCapturerTests {
    @Test func windowModeOffersPasharisOwnOrdinaryWindows() async throws {
        let window = try await showWindow(at: CGPoint(x: 80, y: 80), level: .normal)
        // Thumbnails float above ordinary windows like this one.
        let floating = try await showWindow(at: CGPoint(x: 360, y: 80), level: .floating)
        defer {
            window.orderOut(nil)
            floating.orderOut(nil)
        }

        let ids = try await ScreenCapturer.selectableWindows().map(\.windowID)

        #expect(ids.contains(CGWindowID(window.windowNumber)))
        #expect(!ids.contains(CGWindowID(floating.windowNumber)))
    }

    @Test func pasharisOwnWindowCanBeCaptured() async throws {
        let window = try await showWindow(at: CGPoint(x: 80, y: 80), level: .normal)
        defer { window.orderOut(nil) }

        let windows = try await ScreenCapturer.selectableWindows()
        let picked = try #require(windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let screenshot = try await ScreenCapturer.captureWindow(picked)

        // The picture is the window, not the whole screen. ScreenCaptureKit
        // trims a few points off the edges of the frame, so compare loosely.
        #expect(abs(screenshot.pointSize.width - window.frame.width) <= 8)
        #expect(abs(screenshot.pointSize.height - window.frame.height) <= 8)
    }

    @Test func screenshotsKeepPasharisOrdinaryWindowsAndHideFloatingOnes() async throws {
        let window = try await showWindow(at: CGPoint(x: 80, y: 80), level: .normal)
        let floating = try await showWindow(at: CGPoint(x: 360, y: 80), level: .floating)
        defer {
            window.orderOut(nil)
            floating.orderOut(nil)
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let hidden = ScreenCapturer.ownWindowsToHide(in: content).map(\.windowID)

        #expect(!hidden.contains(CGWindowID(window.windowNumber)))
        #expect(hidden.contains(CGWindowID(floating.windowNumber)))
    }

    /// A small window of the test host, once it is on screen. It appears on
    /// whatever Space is in front, even one that holds a full-screen app.
    private func showWindow(at origin: CGPoint, level: NSWindow.Level) async throws -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: origin, size: CGSize(width: 240, height: 160)),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = level
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.orderFrontRegardless()

        // The window comes on screen a moment later, once the main thread is
        // free to finish showing it, so wait for that.
        let id = CGWindowID(window.windowNumber)
        for _ in 0..<100 {
            let onScreen = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[CFString: Any]] ?? []
            if onScreen.contains(where: { $0[kCGWindowNumber] as? CGWindowID == id }) {
                return window
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("The test window did not come on screen")
        return window
    }
}
