import AppKit

/// Runs a capture from start to finish: permission check, capture, output.
/// The menu (and later the hotkeys) call into this class.
final class CaptureCoordinator {
    private var isCapturing = false

    func captureFullscreen() {
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
                guard let screen = NSScreen.underMouse ?? NSScreen.main else {
                    throw CaptureError.displayNotFound
                }
                let screenshot = try await ScreenCapturer.captureDisplay(screen)
                _ = try await ScreenshotWriter.save(
                    screenshot,
                    in: ScreenshotWriter.defaultDirectory
                )
            } catch {
                show(error)
            }
        }
    }

    private func show(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "The screenshot could not be taken")
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }
}
