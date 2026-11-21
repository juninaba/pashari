import CoreGraphics
import Foundation

/// The hotkeys are not here: the KeyboardShortcuts package stores those
/// itself.
enum Preferences {
    private static let saveDirectoryKey = "saveDirectory"
    private static let appearanceKey = "appearance"
    private static let shutterSoundKey = "shutterSound"
    private static let recordingAreaKey = "recordingArea"

    /// The area recorded last, to start the next recording with: in points
    /// from the top-left corner of the display with `displayID`.
    static func recordingArea(in defaults: UserDefaults = .standard) -> (displayID: CGDirectDisplayID, rect: CGRect)? {
        guard
            let values = defaults.dictionary(forKey: recordingAreaKey),
            let displayID = values["display"] as? Int,
            let x = values["x"] as? Double,
            let y = values["y"] as? Double,
            let width = values["width"] as? Double,
            let height = values["height"] as? Double
        else { return nil }
        return (CGDirectDisplayID(truncatingIfNeeded: displayID), CGRect(x: x, y: y, width: width, height: height))
    }

    static func setRecordingArea(
        _ rect: CGRect,
        onDisplay displayID: CGDirectDisplayID,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(
            [
                "display": Int(displayID),
                "x": Double(rect.minX),
                "y": Double(rect.minY),
                "width": Double(rect.width),
                "height": Double(rect.height),
            ],
            forKey: recordingAreaKey
        )
    }

    /// Silent until the user picks a sound.
    static func shutterSound(in defaults: UserDefaults = .standard) -> ShutterSound {
        defaults.string(forKey: shutterSoundKey).flatMap(ShutterSound.init(rawValue:)) ?? .off
    }

    static func setShutterSound(_ sound: ShutterSound, in defaults: UserDefaults = .standard) {
        defaults.set(sound.rawValue, forKey: shutterSoundKey)
    }

    /// As in macOS until the user picks Light or Dark.
    static func appearance(in defaults: UserDefaults = .standard) -> AppAppearance {
        defaults.string(forKey: appearanceKey).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    static func setAppearance(_ appearance: AppAppearance, in defaults: UserDefaults = .standard) {
        defaults.set(appearance.rawValue, forKey: appearanceKey)
    }

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
