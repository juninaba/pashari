import Testing

@testable import Pashari

@MainActor
struct CaptureCoordinatorTests {
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
