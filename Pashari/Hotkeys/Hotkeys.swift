import KeyboardShortcuts

// The global hotkeys. The KeyboardShortcuts package stores what the user
// picks (in UserDefaults) and listens for the keys system-wide; this file
// only declares which shortcuts exist and what they start with.
extension KeyboardShortcuts.Name {
    // Defaults use Control-Option. They have to stay clear of:
    // - the system's own screenshot shortcuts (Command-Shift-3/4/5 and their
    //   Control variants);
    // - other apps' global shortcuts: the ChatGPT app takes Control-Shift-4
    //   and Control-Option-Shift-4 for its own screenshots. When two apps
    //   register the same keys, macOS tells both, and both start a capture;
    // - Option or Option-Shift alone, which macOS 15 and later refuses for
    //   global shortcuts.
    //
    // A default is saved the first time the app runs, so changing it here
    // does not change it for someone who already has Pashari.
    static let captureArea = Self(
        "captureArea",
        default: .init(.four, modifiers: [.control, .option])
    )
    static let captureWindow = Self(
        "captureWindow",
        default: .init(.five, modifiers: [.control, .option])
    )
    static let captureFullscreen = Self(
        "captureFullscreen",
        default: .init(.three, modifiers: [.control, .option])
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
