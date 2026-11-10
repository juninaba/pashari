import AppKit

/// Receives app lifecycle callbacks from AppKit and owns the top-level objects.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let thumbnailController = ThumbnailController()
    private let editorController = AnnotationEditorController()
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

        // Thumbnail and editor pass screenshots back and forth: "Annotate"
        // on a thumbnail opens an editor, and an editor that is closed
        // without Copy or Save turns back into a thumbnail.
        thumbnailController.onAnnotate = { [editorController] screenshot in
            editorController.open(screenshot)
        }
        editorController.onFinish = { [thumbnailController] screenshot in
            thumbnailController.show(screenshot)
        }

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
