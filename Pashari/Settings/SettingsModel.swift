import Foundation
import Observation

/// The window is kept for the life of the app, and these values can change
/// while it is closed: an external drive chosen as the save folder can be
/// unplugged, which sends saves to the Desktop, the login item can be turned
/// off in System Settings, and recording audio toggles can be changed from
/// the recording bar. So they are read again each time Settings opens (see
/// `SettingsWindowController.show`). Only Settings changes the appearance and
/// the shutter sound, so they are read once.
@Observable
final class SettingsModel {
    var launchAtLogin: Bool
    var saveDirectory: URL
    var shutterSound = Preferences.shutterSound()
    var appearance = Preferences.appearance()
    var recordingAudio: RecordingAudio
    var isRequestingMicrophonePermission = false
    var launchAtLoginError: String?

    private let readLaunchAtLogin: @MainActor () -> Bool
    private let readSaveDirectory: @MainActor () -> URL
    private let readRecordingAudio: @MainActor () -> RecordingAudio

    init(
        readLaunchAtLogin: @escaping @MainActor () -> Bool = { LaunchAtLogin.isEnabled },
        readSaveDirectory: @escaping @MainActor () -> URL = { Preferences.saveDirectory() },
        readRecordingAudio: @escaping @MainActor () -> RecordingAudio = { Preferences.recordingAudio() }
    ) {
        self.readLaunchAtLogin = readLaunchAtLogin
        self.readSaveDirectory = readSaveDirectory
        self.readRecordingAudio = readRecordingAudio
        launchAtLogin = readLaunchAtLogin()
        saveDirectory = readSaveDirectory()
        recordingAudio = readRecordingAudio()
    }

    func reload() {
        launchAtLogin = readLaunchAtLogin()
        saveDirectory = readSaveDirectory()
        recordingAudio = readRecordingAudio()
        launchAtLoginError = nil
    }

    func reloadRecordingAudio() {
        recordingAudio = readRecordingAudio()
    }
}
