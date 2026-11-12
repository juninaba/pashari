import Foundation
import Observation

/// What the Settings window shows.
///
/// The window is kept for the life of the app, and these values can change
/// while it is closed: an external drive chosen as the save folder can be
/// unplugged, which sends saves to the Desktop, and the login item can be
/// turned off in System Settings. So they are read again each time Settings
/// opens (see `SettingsWindowController.show`).
@Observable
final class SettingsModel {
    var launchAtLogin: Bool
    var saveDirectory: URL
    /// Why the last attempt to change the login item failed, if it did.
    var launchAtLoginError: String?

    private let readLaunchAtLogin: @MainActor () -> Bool
    private let readSaveDirectory: @MainActor () -> URL

    /// The values come from the real settings; tests pass readers of their
    /// own.
    init(
        readLaunchAtLogin: @escaping @MainActor () -> Bool = { LaunchAtLogin.isEnabled },
        readSaveDirectory: @escaping @MainActor () -> URL = { Preferences.saveDirectory() }
    ) {
        self.readLaunchAtLogin = readLaunchAtLogin
        self.readSaveDirectory = readSaveDirectory
        launchAtLogin = readLaunchAtLogin()
        saveDirectory = readSaveDirectory()
    }

    /// Reads the settings again, and forgets an old error.
    func reload() {
        launchAtLogin = readLaunchAtLogin()
        saveDirectory = readSaveDirectory()
        launchAtLoginError = nil
    }
}
