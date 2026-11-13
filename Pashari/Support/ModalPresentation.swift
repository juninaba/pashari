import AppKit

enum ModalPresentation {
    /// Close active selection overlays before the dialog takes keyboard focus.
    @discardableResult
    static func run(_ present: () -> NSApplication.ModalResponse) -> NSApplication.ModalResponse {
        OverlayPanel.cancelSelection()
        NSApp.activate()
        return present()
    }
}
