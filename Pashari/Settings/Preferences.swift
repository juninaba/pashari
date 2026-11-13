import Foundation

/// The hotkeys are not here: the KeyboardShortcuts package stores those
/// itself.
enum Preferences {
    private static let saveDirectoryKey = "saveDirectory"

    /// This is the Desktop until the user picks another folder. It is also
    /// the Desktop when the chosen folder is gone, for example on a drive
    /// that is no longer connected, so that saving keeps working.
    static func saveDirectory(in defaults: UserDefaults = .standard) -> URL {
        guard let path = defaults.string(forKey: saveDirectoryKey) else {
            return desktopDirectory
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
            ? URL(fileURLWithPath: path, isDirectory: true)
            : desktopDirectory
    }

    static func setSaveDirectory(_ url: URL, in defaults: UserDefaults = .standard) {
        defaults.set(url.path, forKey: saveDirectoryKey)
    }

    static var desktopDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }
}
