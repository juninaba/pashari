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
    private static let actions: [(name: KeyboardShortcuts.Name, run: (CaptureCoordinator) -> Void)] = [
        (.captureArea, { $0.captureArea() }),
        (.captureWindow, { $0.captureWindow() }),
        (.captureFullscreen, { $0.captureFullscreen() }),
        (.captureScrollingArea, { $0.captureScrollingArea() }),
        (.captureText, { $0.captureText() }),
        (.recordArea, { $0.recordArea() }),
        (.recordWindow, { $0.recordWindow() }),
        (.recordFullscreen, { $0.recordFullscreen() }),
    ]

    static func validate(
        _ shortcut: KeyboardShortcuts.Shortcut,
        for name: KeyboardShortcuts.Name,
        shortcutFor: @MainActor (KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut? = KeyboardShortcuts.getShortcut
    ) -> KeyboardShortcuts.ValidationResult {
        let alreadyAssigned = actions.contains { action in
            action.name != name && shortcutFor(action.name) == shortcut
        }
        if alreadyAssigned {
            return .disallow(reason: String(localized: "This shortcut is already assigned to another Pashari action."))
        }
        return .allow
    }

    static func register(with captureCoordinator: CaptureCoordinator) {
        for action in actions {
            KeyboardShortcuts.onKeyDown(for: action.name) {
                action.run(captureCoordinator)
            }
        }
    }
}
