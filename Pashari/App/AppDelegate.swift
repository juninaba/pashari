import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let thumbnailController: ThumbnailController
    private let editorController: AnnotationEditorController
    private let pinController: PinnedScreenshotController
    private(set) lazy var playerController = RecordingPlayerController(storage: thumbnailController.storage)
    private let settingsWindowController = SettingsWindowController()
    private let makeCaptureCoordinator: @MainActor (ThumbnailController) -> CaptureCoordinator
    private(set) lazy var captureCoordinator = makeCaptureCoordinator(thumbnailController)
    private var statusItemController: StatusItemController?

    lazy var confirmQuit: () -> Bool = { [unowned self] in self.askToQuit() }
    /// The answer to a quit that had to wait for a recording to end.
    lazy var replyToQuit: (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }

    init(
        thumbnailController: ThumbnailController = ThumbnailController(),
        editorController: AnnotationEditorController = AnnotationEditorController(),
        pinController: PinnedScreenshotController? = nil,
        makeCaptureCoordinator: @escaping @MainActor (ThumbnailController) -> CaptureCoordinator = {
            CaptureCoordinator(thumbnailController: $0)
        }
    ) {
        self.thumbnailController = thumbnailController
        self.editorController = editorController
        self.pinController = pinController ?? PinnedScreenshotController(storage: thumbnailController.storage)
        self.makeCaptureCoordinator = makeCaptureCoordinator
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
        thumbnailController.onPin = { [weak self] capture, displayID in
            guard let self else { return }
            if !pinController.show(capture, onDisplay: displayID) {
                thumbnailController.show(capture, onDisplay: displayID)
            }
        }
        pinController.onUnpin = { [thumbnailController] capture, displayID in
            thumbnailController.show(capture, onDisplay: displayID)
        }
        pinController.onAnnotate = { [editorController] screenshot, onClose in
            editorController.open(screenshot, onClose: onClose)
        }
        editorController.onPin = { [weak pinController] screenshot in
            guard let pinController else { throw CaptureError.displayNotFound }
            try await pinController.show(screenshot)
        }
        thumbnailController.onPlay = { [playerController] recording in
            playerController.open(recording)
        }
        playerController.onFinish = { [thumbnailController] recording in
            thumbnailController.show(recording)
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
        // Say at logout: a recording that is running ends first, and joins
        // the thumbnails like any other before the question.
        if captureCoordinator.isRecording {
            Task {
                await captureCoordinator.finishRecording()
                replyToQuit(shouldQuit())
            }
            return .terminateLater
        }
        return shouldQuit() ? .terminateNow : .terminateCancel
    }

    private func shouldQuit() -> Bool {
        guard
            thumbnailController.hasPendingCaptures
                || pinController.hasPendingCaptures
                || editorController.hasOpenEditors
                || playerController.hasOpenPlayers
        else {
            return true
        }
        guard confirmQuit() else {
            pinController.showPendingPins()
            editorController.showEditors()
            playerController.showPlayers()
            return false
        }
        return true
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
            ErrorAlert.show(error, title: String(localized: "Unsaved screenshots or recordings could not be processed"))
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
        alert.messageText = String(localized: "Recover unsaved screenshots and recordings?")
        alert.informativeText = String(
            localized: "Pashari found working screenshots or recordings from earlier runs. Restore them to the thumbnail stack, or discard them to delete the working files."
        )
        alert.addButton(withTitle: String(localized: "Restore"))
        alert.addButton(withTitle: String(localized: "Later")).keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: String(localized: "Remove Unsaved Files")).hasDestructiveAction = true

        return ModalPresentation.run { alert.runModal() }
    }

    private func askToQuit() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Quit Pashari?")
        alert.informativeText = String(
            localized: "Unsaved work in thumbnails, pins, editors or players will be lost."
        )
        // Return keeps the work; quitting requires an explicit choice.
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Quit")).hasDestructiveAction = true

        return ModalPresentation.run { alert.runModal() } == .alertSecondButtonReturn
    }
}
