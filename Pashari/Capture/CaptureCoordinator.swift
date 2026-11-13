import AppKit

final class CaptureCoordinator {
    private let thumbnailController: ThumbnailController
    private let ensurePermission: @MainActor () -> Bool
    private var isCapturing = false

    init(
        thumbnailController: ThumbnailController,
        ensurePermission: @escaping @MainActor () -> Bool = { ScreenRecordingPermission.ensureGranted() }
    ) {
        self.thumbnailController = thumbnailController
        self.ensurePermission = ensurePermission
    }

    func captureFullscreen() {
        run {
            guard let screen = NSScreen.underMouse ?? NSScreen.main else {
                throw CaptureError.displayNotFound
            }
            return try await ScreenCapturer.captureDisplay(screen)
        }
    }

    func captureArea() {
        run {
            let frozenScreens = try await ScreenCapturer.captureAllDisplays()
            return await AreaSelectionSession().run(with: frozenScreens)
        }
    }

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
        guard NSApp.modalWindow == nil else {
            Log.capture.info("Ignored: a modal dialog is open")
            return
        }
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
