import AppKit

final class AnnotationEditorController {
    /// Called with the result of an editor that was closed without Copy or
    /// Save, so that it can go back to a floating thumbnail.
    var onFinish: ((Screenshot) -> Void)?

    private var editors: [AnnotationEditorWindowController] = []

    var hasOpenEditors: Bool { !editors.isEmpty }

    func open(_ screenshot: Screenshot) {
        let editor = AnnotationEditorWindowController(screenshot: screenshot)
        keep(editor)
        editor.show()
    }

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

    /// After cancelling Quit, bring the work forward to be copied or saved.
    func showEditors() {
        for editor in editors {
            editor.window.makeKeyAndOrderFront(nil)
        }
    }
}
