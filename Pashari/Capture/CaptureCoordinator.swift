import AppKit

/// Runs a capture from start to finish: permission check, capture, and
/// handing the result to the floating thumbnail. The menu and the hotkeys
/// call into this class.
final class CaptureCoordinator {
    private let thumbnailController: ThumbnailController
    private var isCapturing = false

    init(thumbnailController: ThumbnailController) {
        self.thumbnailController = thumbnailController
    }

    /// Captures the whole screen the pointer is on.
    func captureFullscreen() {
        run {
            guard let screen = NSScreen.underMouse ?? NSScreen.main else {
                throw CaptureError.displayNotFound
            }
            return try await ScreenCapturer.captureDisplay(screen)
        }
    }

    /// Freezes the screen and lets the user drag out the part to keep.
    func captureArea() {
        run {
            let frozenScreens = try await ScreenCapturer.captureAllDisplays()
            return await AreaSelectionSession().run(with: frozenScreens)
        }
    }

    /// Lets the user click a window and captures just that window.
    func captureWindow() {
        run {
            let windows = try await ScreenCapturer.selectableWindows()
            guard let window = await WindowSelectionSession().run(with: windows) else {
                return nil
            }
            return try await ScreenCapturer.captureWindow(window)
        }
    }

    /// Shared skeleton of every capture mode. `capture` returns the
    /// screenshot, or nil when the user cancelled.
    private func run(_ capture: @escaping () async throws -> Screenshot?) {
        // Ignore a second request while one is still running.
        guard !isCapturing else { return }
        guard ScreenRecordingPermission.ensureGranted() else { return }

        isCapturing = true
        // `Task` starts asynchronous work from a synchronous function. The
        // work still runs on the main thread, but every `await` inside it
        // gives the thread back to the event loop while waiting.
        Task {
            defer { isCapturing = false }
            do {
                guard let screenshot = try await capture() else { return }
                thumbnailController.show(screenshot)
            } catch {
                ErrorAlert.show(error, title: String(localized: "The screenshot could not be taken"))
            }
        }
    }
}
