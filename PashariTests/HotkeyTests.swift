import Foundation
import KeyboardShortcuts
import Testing

@testable import Pashari

@MainActor
struct HotkeyTests {
    private let defaults = [
        KeyboardShortcuts.Name.captureArea,
        .captureWindow,
        .captureFullscreen,
    ].compactMap(\.initialShortcut)

    @Test func areaWindowAndFullscreenCaptureHaveADefault() {
        #expect(defaults.count == 3)
    }

    @Test func scrollAndTextCaptureHaveNoDefault() {
        #expect(KeyboardShortcuts.Name.captureScrollingArea.initialShortcut == nil)
        #expect(KeyboardShortcuts.Name.captureText.initialShortcut == nil)
    }

    @Test func recordingHasNoDefault() {
        #expect(KeyboardShortcuts.Name.recordArea.initialShortcut == nil)
        #expect(KeyboardShortcuts.Name.recordWindow.initialShortcut == nil)
        #expect(KeyboardShortcuts.Name.recordFullscreen.initialShortcut == nil)
    }

    @Test func theDefaultsAreDifferentFromEachOther() {
        #expect(Set(defaults).count == defaults.count)
    }

    @Test func anAssignedShortcutCanOnlyBeRecordedForItsCurrentAction() {
        let action = KeyboardShortcuts.Name("testAction-\(UUID())")
        let other = KeyboardShortcuts.Name("testOtherAction-\(UUID())")
        let shortcut = KeyboardShortcuts.Shortcut(.f19, modifiers: [.command, .control, .option, .shift])
        KeyboardShortcuts.setShortcut(shortcut, for: action)
        defer { KeyboardShortcuts.setShortcut(nil, for: action) }

        #expect(Hotkeys.validate(shortcut, for: action) == .allow)
        #expect(Hotkeys.validate(shortcut, for: other) != .allow)
        #expect(action.shortcut == shortcut)
        #expect(other.shortcut == nil)
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
