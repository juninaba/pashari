import AppKit

enum Clipboard {
    /// `pasteboard` is a parameter so tests can use a private pasteboard
    /// instead of the user's real clipboard.
    static func copy(pngData: Data, to pasteboard: NSPasteboard = .general) throws {
        pasteboard.clearContents()
        guard pasteboard.setData(pngData, forType: .png) else {
            throw CaptureError.cannotWriteClipboard
        }
    }

    /// The file itself, as Finder copies it: apps such as Slack, Messages
    /// and browsers take it from there when it is pasted.
    static func copy(fileURL url: URL, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }
}
