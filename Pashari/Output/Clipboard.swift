import AppKit

enum Clipboard {
    /// Puts a PNG image on the clipboard, replacing what was there.
    ///
    /// `pasteboard` is a parameter so tests can use a private pasteboard
    /// instead of the user's real clipboard.
    static func copy(pngData: Data, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
    }
}
