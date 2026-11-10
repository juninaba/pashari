import AppKit

enum ErrorAlert {
    /// Shows an error in a dialog and waits until the user dismisses it.
    static func show(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription

        // A menu bar app is never the active app on its own, so bring the
        // alert to the front explicitly.
        NSApp.activate()
        alert.runModal()
    }
}
