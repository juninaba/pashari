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
        // Before any window opens, such as the alert below that offers to
        // recover screenshots.
        Preferences.appearance().apply()
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
        recoverInterruptedCaptures()
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
        thumbnailController.storage.removeFiles()
    }

    private func recoverInterruptedCaptures() {
        let storage = thumbnailController.storage
        do {
            try storage.withInterruptedFiles(includeLegacy: canRecoverLegacyCaptures) { files in
                guard !files.isEmpty else { return }
                switch askToRecoverCaptures() {
                case .alertFirstButtonReturn:
                    try thumbnailController.restore(files)
                case .alertThirdButtonReturn:
                    for file in files { try storage.discard(file) }
                default:
                    break
                }
            }
        } catch {
            ErrorAlert.show(error, title: String(localized: "Unsaved screenshots could not be processed"))
        }
    }

    private func canRecoverLegacyCaptures() -> Bool {
        // Older builds did not lock their run directories.
        let bundle = Bundle.main
        let executableName = bundle.executableURL?.lastPathComponent ?? "Pashari"
        return !NSWorkspace.shared.runningApplications.contains { app in
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier, !app.isTerminated else {
                return false
            }
            return app.executableURL?.lastPathComponent == executableName
                || (bundle.bundleIdentifier != nil && app.bundleIdentifier == bundle.bundleIdentifier)
        }
    }

    private func askToRecoverCaptures() -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = String(localized: "Recover unsaved screenshots?")
        alert.informativeText = String(
            localized: "Pashari found working screenshots from earlier runs. Restore them to the thumbnail stack, or discard them to delete the working files."
        )
        alert.addButton(withTitle: String(localized: "Restore"))
        alert.addButton(withTitle: String(localized: "Later")).keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: String(localized: "Remove Unsaved Screenshots")).hasDestructiveAction = true

        return ModalPresentation.run { alert.runModal() }
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
