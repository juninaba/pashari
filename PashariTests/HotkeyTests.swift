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

    @Test func everyCaptureModeHasADefault() {
        #expect(defaults.count == 3)
    }

    @Test func theDefaultsAreDifferentFromEachOther() {
        #expect(Set(defaults).count == defaults.count)
    }

    @Test func theDefaultsStayClearOfShortcutsOthersAlreadyUse() {
        let taken: [KeyboardShortcuts.Shortcut] = [
            // macOS screenshots
            .init(.three, modifiers: [.command, .shift]),
            .init(.four, modifiers: [.command, .shift]),
            .init(.five, modifiers: [.command, .shift]),
            .init(.three, modifiers: [.command, .shift, .control]),
            .init(.four, modifiers: [.command, .shift, .control]),
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
