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
    // No shortcut until the user records one under Settings.
    static let captureScrollingArea = Self("captureScrollingArea")
    // None either. Pressed again, it starts the recording, and then stops it.
    static let recordArea = Self("recordArea")
    // None either. Pressed again while recording, it stops it.
    static let recordWindow = Self("recordWindow")
    static let recordFullscreen = Self("recordFullscreen")
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
        KeyboardShortcuts.onKeyDown(for: .recordArea) {
            captureCoordinator.recordArea()
        }
        KeyboardShortcuts.onKeyDown(for: .recordWindow) {
            captureCoordinator.recordWindow()
        }
        KeyboardShortcuts.onKeyDown(for: .recordFullscreen) {
            captureCoordinator.recordFullscreen()
        }
    }
}
