import AppKit

/// Receives app lifecycle callbacks from AppKit and owns the top-level objects.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let thumbnailController: ThumbnailController
    private let editorController: AnnotationEditorController
    private let settingsWindowController = SettingsWindowController()
    // `lazy`: created on first use. It needs `thumbnailController`, and one
    // stored property cannot refer to another while the object is still
    // being set up.
    private lazy var captureCoordinator = CaptureCoordinator(
        thumbnailController: thumbnailController
    )
    private var statusItemController: StatusItemController?

    /// Tests supply an answer without opening a modal alert.
    lazy var confirmQuit: () -> Bool = { [unowned self] in self.askToQuit() }

    init(
        thumbnailController: ThumbnailController = ThumbnailController(),
        editorController: AnnotationEditorController = AnnotationEditorController()
    ) {
        self.thumbnailController = thumbnailController
        self.editorController = editorController
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Never shown, but it gives the windows ⌘W, ⌘C, ⌘Z and so on.
        NSApp.mainMenu = MainMenu.make()

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

    /// Called when Pashari is opened again while it is already running, for
    /// example from Spotlight or with a double-click in the Finder. macOS
    /// does not start a second copy; it tells the running one instead.
    ///
    /// Pashari answers by showing Settings. Otherwise the menu bar icon would
    /// be the only way in, and macOS hides that icon when the menu bar is too
    /// full to show it, for example next to the notch.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        Log.app.info("Opened again while running: showing Settings")
        settingsWindowController.show()
        // false tells AppKit that the event is handled.
        return false
    }

    /// Asked before Pashari quits, from the menu or because the Mac is
    /// shutting down. Saying no keeps it running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard thumbnailController.hasPendingCaptures || editorController.hasOpenEditors else {
            return .terminateNow
        }
        guard confirmQuit() else {
            editorController.showEditors()
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        CaptureStorage.current.removeFiles()
    }

    private func askToQuit() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Quit Pashari?")
        alert.informativeText = String(
            localized: "Screenshots in thumbnails or the editor have not been copied or saved, and will be lost."
        )
        // Return keeps the work; quitting requires an explicit choice.
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Quit")).hasDestructiveAction = true

        return ModalPresentation.run { alert.runModal() } == .alertSecondButtonReturn
    }
}
