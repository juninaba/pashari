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

    @Test(arguments: [false, true])
    func selectionDoesNotCoverADialogOpenedWhileFetching(windowMode: Bool) async throws {
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
        let screen = try #require(NSScreen.main)
        var started = false
        let selection = Task {
            started = true
            if windowMode {
                let result = await WindowSelectionSession().run(with: [])
                #expect(result == nil)
            } else {
                let result = await AreaSelectionSession().run(with: [
                    FrozenScreen(screen: screen, screenshot: makeScreenshot()),
                ])
                #expect(result == nil)
            }
        }
        while !started { await Task.yield() }

        let overlays = NSApp.windows.compactMap { $0 as? OverlayPanel }.filter(\.isVisible)
        #expect(overlays.isEmpty)
        // If an overlay regresses, cancel it so the test reports a failure
        // instead of leaving its selection continuation waiting for a user.
        for panel in overlays {
            let views = [panel.contentView].compactMap { $0 } + (panel.contentView?.subviews ?? [])
            for view in views.compactMap({ $0 as? SelectionOverlayView }) {
                view.onCancel?()
            }
        }
        await selection.value
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
