import AppKit

/// Receives app lifecycle callbacks from AppKit and owns the top-level objects.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let thumbnailController = ThumbnailController()
    private let settingsWindowController = SettingsWindowController()
    // `lazy`: created on first use. It needs `thumbnailController`, and one
    // stored property cannot refer to another while the object is still
    // being set up.
    private lazy var captureCoordinator = CaptureCoordinator(
        thumbnailController: thumbnailController
    )
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Leftovers from a previous run that did not quit cleanly.
        PendingCapture.removeTemporaryFiles()

        statusItemController = StatusItemController(
            captureCoordinator: captureCoordinator,
            settingsWindowController: settingsWindowController
        )
        Hotkeys.register(with: captureCoordinator)
    }

    func applicationWillTerminate(_ notification: Notification) {
        PendingCapture.removeTemporaryFiles()
    }
}
