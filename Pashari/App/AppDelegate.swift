import AppKit

/// Receives app lifecycle callbacks from AppKit and owns the top-level objects.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let captureCoordinator = CaptureCoordinator()
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(captureCoordinator: captureCoordinator)
    }
}
