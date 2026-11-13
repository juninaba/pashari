import AppKit

enum ErrorAlert {
    static func show(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription

        ModalPresentation.run { alert.runModal() }
    }
}
