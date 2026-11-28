import AppKit
import AVFoundation

enum MicrophonePermission {
    /// What to do when a recording is about to start with the microphone on.
    enum RecordingDecision: Equatable {
        case recordWithMicrophone
        case recordWithoutMicrophone
        case cancel
    }

    /// Choice made in the alert shown when microphone access was denied.
    enum DeniedChoice: Equatable {
        case openSettings
        case recordWithoutMicrophone
        case cancel
    }

    private static let settingsPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"

    static func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func openSystemSettings() {
        if let url = URL(string: settingsPane) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Checks or requests microphone access when the user turns the microphone
    /// toggle on in Settings or the area recording bar.
    static func requestForToggle(
        showDeniedAlert: () -> Void = { _ = showInstructions() }
    ) async -> Bool {
        await requestForToggle(
            status: { authorizationStatus() },
            request: { await AVCaptureDevice.requestAccess(for: .audio) },
            showDeniedAlert: showDeniedAlert
        )
    }

    static func requestForToggle(
        status: () -> AVAuthorizationStatus,
        request: () async -> Bool,
        showDeniedAlert: () -> Void
    ) async -> Bool {
        switch status() {
        case .authorized:
            return true
        case .notDetermined:
            return await request()
        case .denied, .restricted:
            showDeniedAlert()
            return false
        @unknown default:
            showDeniedAlert()
            return false
        }
    }

    /// Resolves whether a recording with `audio` should include the microphone,
    /// fall back to recording without it, or cancel.
    static func resolveAudio(
        _ audio: RecordingAudio,
        using resolve: () async -> RecordingDecision = { await resolveForRecording() }
    ) async -> RecordingAudio? {
        guard audio.microphone else { return audio }
        switch await resolve() {
        case .recordWithMicrophone:
            return audio
        case .recordWithoutMicrophone:
            return RecordingAudio(systemAudio: audio.systemAudio, microphone: false)
        case .cancel:
            return nil
        }
    }

    static func resolveForRecording() async -> RecordingDecision {
        await resolveForRecording(
            status: { authorizationStatus() },
            request: { await AVCaptureDevice.requestAccess(for: .audio) },
            askWhenDenied: { askWhenDeniedForRecording() },
            openSettings: { openSystemSettings() }
        )
    }

    static func resolveForRecording(
        status: () -> AVAuthorizationStatus,
        request: () async -> Bool,
        askWhenDenied: () -> DeniedChoice,
        openSettings: () -> Void
    ) async -> RecordingDecision {
        switch status() {
        case .authorized:
            return .recordWithMicrophone
        case .notDetermined:
            return await request() ? .recordWithMicrophone : .recordWithoutMicrophone
        case .denied, .restricted:
            return decisionWhenDenied(askWhenDenied: askWhenDenied, openSettings: openSettings)
        @unknown default:
            return decisionWhenDenied(askWhenDenied: askWhenDenied, openSettings: openSettings)
        }
    }

    private static func decisionWhenDenied(
        askWhenDenied: () -> DeniedChoice,
        openSettings: () -> Void
    ) -> RecordingDecision {
        switch askWhenDenied() {
        case .recordWithoutMicrophone:
            return .recordWithoutMicrophone
        case .openSettings:
            openSettings()
            return .cancel
        case .cancel:
            return .cancel
        }
    }

    /// Explains how to grant microphone access in System Settings.
    /// Returns true if the user chose to open System Settings.
    ///
    /// Pass `cancelOverlays: false` when the caller has already temporarily
    /// hidden its own overlays and will restore them on cancel.
    @discardableResult
    static func showInstructions(cancelOverlays: Bool = true) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Pashari needs permission to use the microphone")
        alert.informativeText = String(
            localized: "Turn on Pashari under Privacy & Security > Microphone in System Settings."
        )
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let response: NSApplication.ModalResponse
        if cancelOverlays {
            response = ModalPresentation.run { alert.runModal() }
        } else {
            NSApp.activate()
            response = alert.runModal()
        }
        if response == .alertFirstButtonReturn {
            openSystemSettings()
            return true
        }
        return false
    }

    private static func askWhenDeniedForRecording() -> DeniedChoice {
        let alert = NSAlert()
        alert.messageText = String(localized: "Pashari needs permission to use the microphone")
        alert.informativeText = String(
            localized: """
            Turn on Pashari under Privacy & Security > Microphone in System Settings, \
            or continue recording without the microphone.
            """
        )
        alert.addButton(withTitle: String(localized: "Record Without Microphone"))
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"

        switch ModalPresentation.run({ alert.runModal() }) {
        case .alertFirstButtonReturn:
            return .recordWithoutMicrophone
        case .alertSecondButtonReturn:
            return .openSettings
        default:
            return .cancel
        }
    }
}
