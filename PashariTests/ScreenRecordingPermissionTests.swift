import Testing

@testable import Pashari

@MainActor
struct ScreenRecordingPermissionTests {
    /// Stands in for macOS, counting what Pashari asks of it.
    private final class FakeSystem {
        var isGranted = false
        var grantsOnRequest = false
        var requests = 0
        var instructionsShown = 0
        var hasAsked = false

        /// One capture attempt. True when the capture may go ahead.
        func attempt() -> Bool {
            ScreenRecordingPermission.ensureGranted(
                isGranted: { self.isGranted },
                request: {
                    self.requests += 1
                    return self.grantsOnRequest
                },
                showInstructions: { self.instructionsShown += 1 },
                hasAsked: &hasAsked
            )
        }
    }

    @Test func nothingIsAskedWhenThePermissionIsThere() {
        let system = FakeSystem()
        system.isGranted = true

        #expect(system.attempt())
        #expect(system.requests == 0)
        #expect(system.instructionsShown == 0)
    }

    @Test func theFirstRefusalIsLeftToThePromptOfMacOS() {
        let system = FakeSystem()

        #expect(!system.attempt())
        #expect(system.requests == 1)
        #expect(system.instructionsShown == 0)
    }

    @Test func everyLaterRefusalAsksAgainAndExplains() {
        let system = FakeSystem()
        _ = system.attempt()

        #expect(!system.attempt())
        #expect(!system.attempt())
        // Asking again puts Pashari back in the list in System Settings,
        // should its entry have been removed since the first attempt.
        #expect(system.requests == 3)
        #expect(system.instructionsShown == 2)
    }

    @Test func aRequestThatIsGrantedNeedsNoExplanation() {
        let system = FakeSystem()
        _ = system.attempt()
        system.grantsOnRequest = true

        #expect(system.attempt())
        #expect(system.instructionsShown == 0)
    }
}
