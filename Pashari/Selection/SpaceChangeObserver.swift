import AppKit

/// Every desktop, and every app in full screen, is a Space of its own. The
/// selection overlays follow the user from Space to Space (see
/// `OverlayPanel`), but what they show belongs to the Space the user left,
/// and the app on the new Space takes the keyboard. The selection sessions
/// use this to catch up.
final class SpaceChangeObserver {
    private var token: NSObjectProtocol?

    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            // `queue: .main` runs this on the main thread; this tells Swift so.
            MainActor.assumeIsolated {
                onChange()
            }
        }
    }

    func stop() {
        if let token {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        token = nil
    }
}
