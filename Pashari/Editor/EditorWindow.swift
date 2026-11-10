import AppKit

/// The editor's keyboard shortcuts.
enum EditorKeyCommand: Equatable {
    case undo, redo, copy, save, close

    /// The command for Command plus `key`, or nil when there is none.
    init?(key: String, shift: Bool) {
        switch (key, shift) {
        case ("z", false): self = .undo
        case ("z", true): self = .redo
        case ("c", false): self = .copy
        case ("s", false): self = .save
        case ("w", false): self = .close
        default: return nil
        }
    }
}

/// The editor's window.
///
/// In an ordinary app, shortcuts such as Command-Z and Command-C work
/// because they belong to items in the menu bar's Edit menu. Pashari has no
/// menu bar of its own, so the window handles them here.
final class EditorWindow: NSWindow {
    var onKeyCommand: ((EditorKeyCommand) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard
            modifiers.contains(.command),
            modifiers.isDisjoint(with: [.option, .control]),
            let key = event.charactersIgnoringModifiers?.lowercased()
        else {
            return super.performKeyEquivalent(with: event)
        }
        let shift = modifiers.contains(.shift)

        // While the user is typing with the text tool, the shortcuts must
        // act on the text being typed, not on the image.
        if firstResponder is NSTextView {
            if let action = Self.textEditingAction(key: key, shift: shift) {
                return NSApp.sendAction(action, to: nil, from: self)
            }
            return super.performKeyEquivalent(with: event)
        }

        if let command = EditorKeyCommand(key: key, shift: shift) {
            onKeyCommand?(command)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The standard text editing action for Command plus `key`.
    static func textEditingAction(key: String, shift: Bool) -> Selector? {
        switch (key, shift) {
        case ("x", false): #selector(NSText.cut(_:))
        case ("c", false): #selector(NSText.copy(_:))
        case ("v", false): #selector(NSText.paste(_:))
        case ("a", false): #selector(NSText.selectAll(_:))
        case ("z", false): Selector(("undo:"))
        case ("z", true): Selector(("redo:"))
        default: nil
        }
    }
}

/// Keeps the image in the middle of the scroll view when it is smaller than
/// the visible area. By default a scroll view pins its content to a corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let documentFrame = documentView?.frame else { return bounds }

        if documentFrame.width < bounds.width {
            bounds.origin.x = documentFrame.midX - bounds.width / 2
        }
        if documentFrame.height < bounds.height {
            bounds.origin.y = documentFrame.midY - bounds.height / 2
        }
        return bounds
    }
}
