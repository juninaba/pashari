import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // macOS's own screenshots use Command-Shift-3 and Command-Shift-4, and
    // they are on until the user turns them off. Pashari is meant to replace
    // them, so they have to be turned off under System Settings > Keyboard >
    // Keyboard Shortcuts > Screenshots (the README says so).
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
    // Area capture's shortcut with Option, since scroll capture starts with
    // picking an area too. macOS keeps Command-Shift-5 for its toolbar, which
    // also records the screen, and Command-Shift-6 for a picture of the
    // Touch Bar.
    static let captureScrollingArea = Self(
        "captureScrollingArea",
        default: .init(.two, modifiers: [.command, .shift, .option])
    )
}

enum Hotkeys {
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
        KeyboardShortcuts.onKeyDown(for: .captureScrollingArea) {
            captureCoordinator.captureScrollingArea()
        }
    }
}
