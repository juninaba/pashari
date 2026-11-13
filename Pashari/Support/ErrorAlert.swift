import AppKit

enum ErrorAlert {
    /// Shows an error in a dialog and waits until the user dismisses it.
    static func show(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription

        ModalPresentation.run { alert.runModal() }
    }
}
