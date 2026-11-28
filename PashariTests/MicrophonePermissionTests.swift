import AVFoundation
import Testing

@testable import Pashari

@MainActor
struct MicrophonePermissionTests {
    @Test func toggleReturnsTrueImmediatelyWhenAuthorized() async {
        var requests = 0
        var alerts = 0

        let allowed = await MicrophonePermission.requestForToggle(
            status: { .authorized },
            request: {
                requests += 1
                return true
            },
            showDeniedAlert: { alerts += 1 }
        )

        #expect(allowed)
        #expect(requests == 0)
        #expect(alerts == 0)
    }

    @Test func toggleRequestsAccessWhenNotDetermined() async {
        var requests = 0
        var alerts = 0

        let granted = await MicrophonePermission.requestForToggle(
            status: { .notDetermined },
            request: {
                requests += 1
                return true
            },
            showDeniedAlert: { alerts += 1 }
        )
        let denied = await MicrophonePermission.requestForToggle(
            status: { .notDetermined },
            request: {
                requests += 1
                return false
            },
            showDeniedAlert: { alerts += 1 }
        )

        #expect(granted)
        #expect(!denied)
        #expect(requests == 2)
        #expect(alerts == 0)
    }

    @Test(arguments: [AVAuthorizationStatus.denied, .restricted])
    func toggleShowsGuidanceAlertWhenDeniedOrRestricted(_ status: AVAuthorizationStatus) async {
        var requests = 0
        var alerts = 0

        let allowed = await MicrophonePermission.requestForToggle(
            status: { status },
            request: {
                requests += 1
                return true
            },
            showDeniedAlert: { alerts += 1 }
        )

        #expect(!allowed)
        #expect(requests == 0)
        #expect(alerts == 1)
    }

    @Test func recordingFallsBackOrCancelsAccordingToDeniedAlertChoice() async {
        var settingsOpened = 0

        let fallback = await MicrophonePermission.resolveForRecording(
            status: { .denied },
            request: { true },
            askWhenDenied: { .recordWithoutMicrophone },
            openSettings: { settingsOpened += 1 }
        )
        #expect(fallback == .recordWithoutMicrophone)
        #expect(settingsOpened == 0)

        let openedSettings = await MicrophonePermission.resolveForRecording(
            status: { .denied },
            request: { true },
            askWhenDenied: { .openSettings },
            openSettings: { settingsOpened += 1 }
        )
        #expect(openedSettings == .cancel)
        #expect(settingsOpened == 1)

        let cancelled = await MicrophonePermission.resolveForRecording(
            status: { .restricted },
            request: { true },
            askWhenDenied: { .cancel },
            openSettings: { settingsOpened += 1 }
        )
        #expect(cancelled == .cancel)
        #expect(settingsOpened == 1)
    }

    @Test func recordingRequestsWhenNotDeterminedAndFallsBackIfRefused() async {
        let granted = await MicrophonePermission.resolveForRecording(
            status: { .notDetermined },
            request: { true },
            askWhenDenied: { .cancel },
            openSettings: {}
        )
        let refused = await MicrophonePermission.resolveForRecording(
            status: { .notDetermined },
            request: { false },
            askWhenDenied: { .cancel },
            openSettings: {}
        )

        #expect(granted == .recordWithMicrophone)
        #expect(refused == .recordWithoutMicrophone)
    }

    @Test func resolveAudioSkipsPermissionCheckWhenMicrophoneIsOffAndPreservesSystemAudioOnFallback() async {
        var checks = 0
        let systemOnly = await MicrophonePermission.resolveAudio(
            RecordingAudio(systemAudio: true, microphone: false),
            using: {
                checks += 1
                return .cancel
            }
        )
        #expect(systemOnly == RecordingAudio(systemAudio: true, microphone: false))
        #expect(checks == 0)

        let fallback = await MicrophonePermission.resolveAudio(
            RecordingAudio(systemAudio: true, microphone: true),
            using: {
                checks += 1
                return .recordWithoutMicrophone
            }
        )
        #expect(fallback == RecordingAudio(systemAudio: true, microphone: false))
        #expect(checks == 1)

        let cancelled = await MicrophonePermission.resolveAudio(
            RecordingAudio(systemAudio: true, microphone: true),
            using: { .cancel }
        )
        #expect(cancelled == nil)
    }
}
