import AppKit

enum ModalPresentation {
    /// Close active selection overlays and end any running recording before
    /// the dialog takes keyboard focus.
    @discardableResult
    static func run(_ present: () -> NSApplication.ModalResponse) -> NSApplication.ModalResponse {
        OverlayPanel.cancelSelection()
        RecordingControlPanel.interruptRecording()
        NSApp.activate()
        return present()
    }
}
