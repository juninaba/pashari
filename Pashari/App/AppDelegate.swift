import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let thumbnailController: ThumbnailController
    private let editorController: AnnotationEditorController
    private let settingsWindowController = SettingsWindowController()
    private lazy var captureCoordinator = CaptureCoordinator(
        thumbnailController: thumbnailController
    )
    private var statusItemController: StatusItemController?

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
        NSApp.mainMenu = MainMenu.make()

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

    /// Pashari answers by showing Settings. Otherwise the menu bar icon would
    /// be the only way in, and macOS hides that icon when the menu bar is too
    /// full to show it, for example next to the notch.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        Log.app.info("Opened again while running: showing Settings")
        settingsWindowController.show()
        return false
    }

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
