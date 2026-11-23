import AppKit

final class FullscreenRecordingSession: RecordingSession {
    var onRecordingChange: ((Bool) -> Void)? {
        get { runner.onRecordingChange }
        set { runner.onRecordingChange = newValue }
    }

    var isRecording: Bool { runner.isRecording }

    private let storage: CaptureStorage
    private let runner = RecordingRunner()

    init(storage: CaptureStorage) {
        self.storage = storage
    }

    func run() async throws -> Recording? {
        guard let screen = NSScreen.underMouse ?? NSScreen.main else {
            throw CaptureError.displayNotFound
        }
        return try await runner.record(
            storage: storage,
            barAnchor: (rect: screen.visibleFrame, screen: screen),
            makeRecorder: { [runner] url, onStart, onFailure in
                let filter = try await ScreenCapturer.recordingFilter(for: screen)
                guard !runner.hasEnded else { return nil }
                return try ScreenRecorder(filter: filter, url: url, onStart: onStart, onFailure: onFailure)
            }
        )
    }

    func advance() {
        stop()
    }

    func stop() {
        runner.stop()
    }
}
