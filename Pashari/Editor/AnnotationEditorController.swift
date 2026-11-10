import AppKit

/// Opens editor windows and keeps them alive while they are on screen.
final class AnnotationEditorController {
    /// Called with the result of an editor that was closed without Copy or
    /// Save, so that it can go back to a floating thumbnail.
    var onFinish: ((Screenshot) -> Void)?

    // A window controller nobody references is destroyed, and its window
    // with it. Holding the open ones here is what keeps them on screen.
    private var editors: [AnnotationEditorWindowController] = []

    func open(_ screenshot: Screenshot) {
        let editor = AnnotationEditorWindowController(screenshot: screenshot)
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
        editor.show()
    }
}
