import AppKit

/// Runs a capture from start to finish: permission check, capture, and
/// handing the result to the floating thumbnail. The menu and the hotkeys
/// call into this class.
final class CaptureCoordinator {
    private let thumbnailController: ThumbnailController
    /// Checks the Screen Recording permission, and guides the user to System
    /// Settings when it is missing. Tests pass in their own.
    private let ensurePermission: @MainActor () -> Bool
    private var isCapturing = false

    init(
        thumbnailController: ThumbnailController,
        ensurePermission: @escaping @MainActor () -> Bool = { ScreenRecordingPermission.ensureGranted() }
    ) {
        self.thumbnailController = thumbnailController
        self.ensurePermission = ensurePermission
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
        // Let the user answer an open dialog before starting another capture.
        guard NSApp.modalWindow == nil else {
            Log.capture.info("Ignored: a modal dialog is open")
            return
        }
        // Ignore a second request while one is still running.
        guard !isCapturing else {
            Log.capture.info("Ignored: a capture is already running")
            return
        }
        // Set before the permission check, which can show an alert. Should a
        // hotkey get through while the alert waits for the user, it must not
        // start a second check, with a second alert on top of the first.
        isCapturing = true
        guard ensurePermission() else {
            isCapturing = false
            Log.capture.info("Stopped: no Screen Recording permission")
            return
        }
        Log.capture.info("Capture started")

        // `Task` starts asynchronous work from a synchronous function. The
        // work still runs on the main thread, but every `await` inside it
        // gives the thread back to the event loop while waiting.
        Task {
            defer { isCapturing = false }
            do {
                guard let screenshot = try await capture() else {
                    Log.capture.info("Capture cancelled")
                    return
                }
                Log.capture.info("Captured \(screenshot.image.width)x\(screenshot.image.height) px")
                thumbnailController.show(screenshot)
            } catch {
                Log.capture.error("Capture failed: \(error.localizedDescription, privacy: .public)")
                ErrorAlert.show(error, title: String(localized: "The screenshot could not be taken"))
            }
        }
    }
}
