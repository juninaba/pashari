import AppKit

/// The open players, as `AnnotationEditorController` keeps the editors.
final class RecordingPlayerController {
    /// Called with a recording whose player was closed without Copy or
    /// Save, so that it can go back to a floating thumbnail.
    var onFinish: ((Recording) -> Void)?

    private let storage: CaptureStorage
    private var players: [RecordingPlayerWindowController] = []

    init(storage: CaptureStorage) {
        self.storage = storage
    }

    var hasOpenPlayers: Bool { !players.isEmpty }

    func open(_ recording: Recording) {
        let player = RecordingPlayerWindowController(recording: recording, storage: storage)
        player.onClose = { [weak self, weak player] result in
            if let result {
                self?.onFinish?(result)
            }
            // Let go of the player a moment later, not right now: this runs
            // while the window is still in the middle of closing.
            DispatchQueue.main.async {
                self?.players.removeAll { $0 === player }
            }
        }
        players.append(player)
        player.show()
    }

    /// After cancelling Quit, bring the recordings forward to be copied or
    /// saved.
    func showPlayers() {
        // Closing clears the delegate before the player is released.
        for player in players where player.window.delegate != nil {
            player.window.makeKeyAndOrderFront(nil)
        }
    }
}
