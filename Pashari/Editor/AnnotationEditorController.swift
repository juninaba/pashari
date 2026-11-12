import AppKit

/// Opens editor windows and keeps them alive while they are on screen.
final class AnnotationEditorController {
    /// Called with the result of an editor that was closed without Copy or
    /// Save, so that it can go back to a floating thumbnail.
    var onFinish: ((Screenshot) -> Void)?

    /// Asks whether to quit even though editors are open, and returns the
    /// answer. Tests put in an answer of their own.
    lazy var confirmQuit: () -> Bool = { [unowned self] in self.askToQuit() }

    // A window controller nobody references is destroyed, and its window
    // with it. Holding the open ones here is what keeps them on screen.
    private var editors: [AnnotationEditorWindowController] = []

    func open(_ screenshot: Screenshot) {
        let editor = AnnotationEditorWindowController(screenshot: screenshot)
        keep(editor)
        editor.show()
    }

    /// Holds on to `editor` until its window closes.
    func keep(_ editor: AnnotationEditorWindowController) {
        editor.onClose = { [weak self, weak editor] result in
            if let result {
                self?.onFinish?(result)
            }
            // Let go of the editor a moment later, not right now: this runs
            // while the window is still in the middle of closing.
            DispatchQueue.main.async {
                self?.editors.removeAll { $0 === editor }
            }
        }
        editors.append(editor)
    }

    /// Whether Pashari may quit now. A screenshot open in an editor exists
    /// nowhere else, so with editors open the user is asked first.
    func mayQuit() -> Bool {
        editors.isEmpty || confirmQuit()
    }

    private func askToQuit() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Quit Pashari?")
        alert.informativeText = String(
            localized: "What is open in the editor has not been copied or saved, and will be lost."
        )
        // Cancel comes first, which makes it the button Return presses: a
        // hurried Return keeps the work.
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Quit")).hasDestructiveAction = true

        // A menu bar app is never the active app on its own, so bring the
        // alert to the front explicitly.
        NSApp.activate()
        guard alert.runModal() == .alertSecondButtonReturn else {
            // Staying: bring the editors forward, so their work can be
            // copied or saved.
            for editor in editors {
                editor.window.makeKeyAndOrderFront(nil)
            }
            return false
        }
        return true
    }
}
