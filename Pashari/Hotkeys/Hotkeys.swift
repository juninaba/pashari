import KeyboardShortcuts

// The global hotkeys. The KeyboardShortcuts package stores what the user
// picks (in UserDefaults) and listens for the keys system-wide; this file
// only declares which shortcuts exist and what they start with.
extension KeyboardShortcuts.Name {
    // Defaults use Control-Shift so they stay clear of the system's own
    // screenshot shortcuts (Command-Shift-3/4/5 and their Control variants).
    static let captureArea = Self(
        "captureArea",
        default: .init(.four, modifiers: [.control, .shift])
    )
    static let captureWindow = Self(
        "captureWindow",
        default: .init(.five, modifiers: [.control, .shift])
    )
    static let captureFullscreen = Self(
        "captureFullscreen",
        default: .init(.three, modifiers: [.control, .shift])
    )
}

enum Hotkeys {
    /// Starts listening. The handlers keep working after the user changes a
    /// shortcut in Settings, because they are tied to the name, not the keys.
    static func register(with captureCoordinator: CaptureCoordinator) {
        KeyboardShortcuts.onKeyDown(for: .captureArea) {
            captureCoordinator.captureArea()
        }
        KeyboardShortcuts.onKeyDown(for: .captureWindow) {
            captureCoordinator.captureWindow()
        }
        KeyboardShortcuts.onKeyDown(for: .captureFullscreen) {
            captureCoordinator.captureFullscreen()
        }
    }
}
