import AppKit

final class AnnotationEditorController {
    /// Returns an edited screenshot to the thumbnail stack when the editor
    /// closes without exporting it.
    var onFinish: ((Screenshot) -> Void)?
    var onPin: ((Screenshot) async throws -> Void)?

    private var editors: [AnnotationEditorWindowController] = []

    var hasOpenEditors: Bool { !editors.isEmpty }

    func open(_ screenshot: Screenshot, onClose: ((Screenshot?) -> Void)? = nil) {
        let editor = AnnotationEditorWindowController(screenshot: screenshot)
        keep(editor, onClose: onClose)
        editor.show()
    }

    func keep(_ editor: AnnotationEditorWindowController, onClose: ((Screenshot?) -> Void)? = nil) {
        editor.onPin = onPin
        editor.onClose = { [weak self, weak editor] result in
            if let onClose {
                onClose(result)
            } else if let result {
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

    /// After cancelling Quit, bring the work forward to be copied or saved.
    func showEditors() {
        // Closing clears the delegate before the editor is released.
        for editor in editors where editor.window.delegate != nil {
            editor.window.makeKeyAndOrderFront(nil)
        }
    }
}
