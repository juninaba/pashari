import AppKit
import Testing

@testable import Pashari

@MainActor
@Suite(.serialized)
struct CaptureCoordinatorTests {
    @Test func aModalDialogBlocksAllCaptureModesUntilItCloses() throws {
        var permissionChecks = 0
        let coordinator = CaptureCoordinator(thumbnailController: ThumbnailController()) {
            permissionChecks += 1
            return false
        }
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: .titled,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }

        do {
            let session = NSApp.beginModalSession(for: window)
            defer { NSApp.endModalSession(session) }
            NSApp.runModalSession(session)
            try #require(NSApp.modalWindow === window)

            coordinator.captureArea()
            coordinator.captureWindow()
            coordinator.captureFullscreen()
            #expect(permissionChecks == 0)
        }

        coordinator.captureFullscreen()
        #expect(permissionChecks == 1)
    }

    @Test func anExistingOverlayRemainsEligibleForInputDuringAModalSession() throws {
        let screen = try #require(NSScreen.main)
        let overlay = OverlayPanel(screen: screen)
        overlay.setFrame(CGRect(x: 100, y: 100, width: 180, height: 100), display: false)
        overlay.orderFrontRegardless()
        defer { overlay.orderOut(nil) }

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: .titled,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let modal = NSApp.beginModalSession(for: window)
        defer {
            NSApp.endModalSession(modal)
            window.orderOut(nil)
        }
        NSApp.runModalSession(modal)
        try #require(NSApp.modalWindow === window)
        // AppKit uses this capability to route mouse and keyboard events
        // outside the modal window. Synthetic postEvent clicks don't reliably
        // pass through that system routing in an XCTest host.
        #expect(overlay.worksWhenModal)
    }

    @Test func aRequestWhileThePermissionAlertIsOpenIsIgnored() {
        let state = AlertState()
        let coordinator = CaptureCoordinator(thumbnailController: ThumbnailController()) {
            state.checks += 1
            // The alert is open, and the user presses the hotkey again.
            if state.checks == 1 {
                state.coordinator?.captureFullscreen()
            }
            return false
        }
        state.coordinator = coordinator

        coordinator.captureFullscreen()
        #expect(state.checks == 1)

        // Once the alert is closed, the next request is checked again.
        coordinator.captureFullscreen()
        #expect(state.checks == 2)
    }

    /// What the stand-in permission check sees and counts.
    private final class AlertState {
        var checks = 0
        weak var coordinator: CaptureCoordinator?
    }
}
