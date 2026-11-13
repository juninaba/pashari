import KeyboardShortcuts

// The global hotkeys. The KeyboardShortcuts package stores what the user
// picks (in UserDefaults) and listens for the keys system-wide; this file
// only declares which shortcuts exist and what they start with.
extension KeyboardShortcuts.Name {
    // Defaults are Command-Shift-2, 3 and 4, in the order of the menu. They
    // do not keep macOS's meanings: there, Command-Shift-3 takes the full
    // screen and Command-Shift-4 an area.
    //
    // macOS's own screenshots use Command-Shift-3 and Command-Shift-4, and
    // they are on until the user turns them off. Pashari is meant to replace
    // them, so they have to be turned off under System Settings > Keyboard >
    // Keyboard Shortcuts > Screenshots (the README says so).
    //
    // The defaults still stay clear of:
    // - the rest of macOS's screenshot shortcuts: Command-Shift-5, and the
    //   Control variants of 3 and 4, which copy to the clipboard;
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
        default: .init(.two, modifiers: [.command, .shift])
    )
    static let captureWindow = Self(
        "captureWindow",
        default: .init(.three, modifiers: [.command, .shift])
    )
    static let captureFullscreen = Self(
        "captureFullscreen",
        default: .init(.four, modifiers: [.command, .shift])
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
