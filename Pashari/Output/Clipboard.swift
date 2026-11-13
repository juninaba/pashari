import AppKit

enum Clipboard {
    /// `pasteboard` is a parameter so tests can use a private pasteboard
    /// instead of the user's real clipboard.
    static func copy(pngData: Data, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
    }
}
