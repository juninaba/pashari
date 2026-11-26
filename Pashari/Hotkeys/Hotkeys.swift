import Foundation
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
        initial: .init(.two, modifiers: [.command, .shift])
    )
    static let captureWindow = Self(
        "captureWindow",
        initial: .init(.three, modifiers: [.command, .shift])
    )
    static let captureFullscreen = Self(
        "captureFullscreen",
        initial: .init(.four, modifiers: [.command, .shift])
    )
    // No shortcuts until the user records them under Settings.
    static let captureScrollingArea = Self("captureScrollingArea")
    static let captureText = Self("captureText")
    // None either. Pressed again, it starts the recording, and then stops it.
    static let recordArea = Self("recordArea")
    // None either. Pressed again while recording, it stops it.
    static let recordWindow = Self("recordWindow")
    static let recordFullscreen = Self("recordFullscreen")
}

enum Hotkeys {
    static func validate(
        _ shortcut: KeyboardShortcuts.Shortcut, for name: KeyboardShortcuts.Name
    ) -> KeyboardShortcuts.ValidationResult {
        let alreadyAssigned = KeyboardShortcuts.storedNames.contains {
            $0.rawValue != name.rawValue && $0.shortcut == shortcut
        }
        if alreadyAssigned {
            return .disallow(reason: String(localized: "This shortcut is already assigned to another Pashari action."))
        }
        return .allow
    }

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
        KeyboardShortcuts.onKeyDown(for: .captureText) {
            captureCoordinator.captureText()
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
