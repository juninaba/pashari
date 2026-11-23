import KeyboardShortcuts
import Testing

@testable import Pashari

@MainActor
struct HotkeyTests {
    private let defaults = [
        KeyboardShortcuts.Name.captureArea,
        .captureWindow,
        .captureFullscreen,
    ].compactMap(\.defaultShortcut)

    @Test func areaWindowAndFullscreenCaptureHaveADefault() {
        #expect(defaults.count == 3)
    }

    @Test func scrollCaptureHasNoDefault() {
        #expect(KeyboardShortcuts.Name.captureScrollingArea.defaultShortcut == nil)
    }

    @Test func recordingHasNoDefault() {
        #expect(KeyboardShortcuts.Name.recordArea.defaultShortcut == nil)
        #expect(KeyboardShortcuts.Name.recordWindow.defaultShortcut == nil)
        #expect(KeyboardShortcuts.Name.recordFullscreen.defaultShortcut == nil)
    }

    @Test func theDefaultsAreDifferentFromEachOther() {
        #expect(Set(defaults).count == defaults.count)
    }

    @Test func theDefaultsStayClearOfShortcutsOthersAlreadyUse() {
        let taken: [KeyboardShortcuts.Shortcut] = [
            // macOS screenshots. Command-Shift-3 and 4 are not here: the
            // defaults take those over on purpose (see Hotkeys.swift).
            .init(.five, modifiers: [.command, .shift]),
            .init(.three, modifiers: [.command, .shift, .control]),
            .init(.four, modifiers: [.command, .shift, .control]),
            .init(.five, modifiers: [.command, .shift, .control]),
            // Pictures of the Touch Bar
            .init(.six, modifiers: [.command, .shift]),
            .init(.six, modifiers: [.command, .shift, .control]),
            // The ChatGPT app's screenshots
            .init(.four, modifiers: [.control, .shift]),
            .init(.four, modifiers: [.control, .option, .shift]),
        ]
        #expect(Set(defaults).isDisjoint(with: taken))
    }

    /// macOS 15 and later refuse global shortcuts whose only modifiers are
    /// Option or Option-Shift.
    @Test func theDefaultsDoNotRelyOnOptionAlone() {
        for shortcut in defaults {
            #expect(!shortcut.modifiers.subtracting([.option, .shift]).isEmpty)
        }
    }
}
