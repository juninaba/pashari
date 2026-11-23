import AppKit

/// Common interface for a recording mode (`AreaRecordingSession`,
/// `WindowRecordingSession`), so `CaptureCoordinator` treats them alike.
protocol RecordingSession: AnyObject {
    var onRecordingChange: ((Bool) -> Void)? { get set }
    /// True once recording has begun, not while the user is picking what to
    /// record.
    var isRecording: Bool { get }
    func run() async throws -> Recording?
    /// The mode's own hotkey pressed again.
    func advance()
    func stop()
}

/// Runs the recording half of a recording session: shows the bar (and any
/// area overlay), starts the `ScreenRecorder`, updates the bar on a timer,
/// stops on user action, a modal dialog, the five-minute limit or a stream
/// error, and finishes the MP4 file.
final class RecordingRunner {
    private enum Ending {
        case done
        /// A dialog opened, such as an error, and needs the user now.
        case interrupted
        case failed(Error)
    }

    /// Called with true when recording begins, and with false when it ends.
    var onRecordingChange: ((Bool) -> Void)?

    private(set) var isRecording = false
    var hasEnded: Bool { ending != nil }

    let controls: RecordingControlPanel
    private var recorder: ScreenRecorder?
    private var frameOverlay: OverlayPanel?
    private var recordingURL: URL?
    private var startedAt: Date?
    private var timer: Timer?
    private var shouldEnd: (() -> Bool)?
    private var ending: Ending?
    private var endingContinuation: CheckedContinuation<Ending, Never>?

    init(controls: RecordingControlPanel = RecordingControlPanel()) {
        self.controls = controls
    }

    func stop() {
        end(.done)
    }

    func interrupt() {
        end(.interrupted)
    }

    /// Records into a new working directory inside `storage`.
    /// `barAnchor` is in AppKit screen coordinates; when nil, the bar still
    /// opens on the current screen. `makeRecorder` creates (without starting)
    /// the recorder, or returns nil if the session was ended while preparing.
    func record(
        storage: CaptureStorage,
        barAnchor: (rect: CGRect, screen: NSScreen)?,
        overlay: OverlayPanel? = nil,
        shouldEnd: (() -> Bool)? = nil,
        makeRecorder: (
            _ url: URL,
            _ onStart: @escaping @Sendable () -> Void,
            _ onFailure: @escaping @Sendable (Error) -> Void
        ) async throws -> ScreenRecorder?
    ) async throws -> Recording? {
        isRecording = true
        self.shouldEnd = shouldEnd
        onRecordingChange?(true)
        defer {
            isRecording = false
            self.shouldEnd = nil
            timer?.invalidate()
            timer = nil
            recorder = nil
            hideRecordingPanels()
            onRecordingChange?(false)
        }
        showRecordingPanels(barAnchor: barAnchor, overlay: overlay)

        let capturedAt = Date()
        let folder = try storage.makeCaptureDirectory()
        let url = folder.appending(path: ScreenshotWriter.fileName(capturedAt: capturedAt, pathExtension: "mp4"))
        recordingURL = url
        let recorder: ScreenRecorder
        do {
            guard let created = try await makeRecorder(
                url,
                { [weak self] in Task { @MainActor in self?.didStartRecording() } },
                { [weak self] error in Task { @MainActor in self?.end(.failed(error)) } }
            ) else {
                try? FileManager.default.removeItem(at: folder)
                return nil
            }
            guard ending == nil else {
                try? FileManager.default.removeItem(at: folder)
                return nil
            }
            // Before it starts, so that an ending from now on reaches it.
            self.recorder = created
            try await created.start()
            recorder = created
        } catch {
            self.recorder = nil
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        startTimer()
        Log.capture.info("Recording started")

        let ending = await waitForEnding()
        timer?.invalidate()
        timer = nil
        let duration: TimeInterval?
        do {
            duration = try await recorder.stop()
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        guard let duration else {
            // Not a single frame came, as when Stop was clicked at once.
            try? FileManager.default.removeItem(at: folder)
            if case .failed(let error) = ending { throw error }
            return nil
        }
        // After a failure too, what was recorded until then is kept.
        Log.capture.info("Recording ended after \(duration, format: .fixed(precision: 1)) s")
        return Recording(url: url, pointSize: recorder.pointSize, duration: duration, capturedAt: capturedAt)
    }

    private func didStartRecording() {
        guard ending == nil, startedAt == nil else { return }
        startedAt = Date()
        showProgress()
    }

    private func startTimer() {
        guard ending == nil, timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Also while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard ending == nil else { return }
        if shouldEnd?() == true {
            end(.done)
            return
        }
        showProgress()
    }

    private func showProgress() {
        guard ending == nil, let startedAt, let recordingURL else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= RecordingWriter.maximumDuration.seconds {
            Log.capture.info("Recording reached its longest")
            end(.done)
            return
        }
        controls.show(.recording(elapsed: elapsed, bytes: ScreenRecorder.bytesWritten(to: recordingURL)))
    }

    private func end(_ ending: Ending) {
        guard isRecording, self.ending == nil else { return }
        // Now: a dialog that ends the recording keeps the main thread busy
        // until it closes, and the recording must not go on meanwhile.
        recorder?.end()
        self.ending = ending
        controls.disableButtons()
        endingContinuation?.resume(returning: ending)
        endingContinuation = nil
    }

    /// The user may already have stopped while the recording was starting.
    private func waitForEnding() async -> Ending {
        if let ending { return ending }
        return await withCheckedContinuation { continuation in
            endingContinuation = continuation
        }
    }

    private func showRecordingPanels(barAnchor: (rect: CGRect, screen: NSScreen)?, overlay: OverlayPanel?) {
        if let overlay {
            // A dialog that opens meanwhile, such as an error, ends the
            // recording, and keeps what was recorded (see `ModalPresentation`).
            overlay.onCancel = { [weak self] in self?.interrupt() }
            overlay.orderFrontRegardless()
            frameOverlay = overlay
        }

        controls.onStop = { [weak self] in self?.stop() }
        controls.onInterrupt = { [weak self] in self?.interrupt() }
        controls.show(.preparing)
        if let barAnchor {
            controls.place(nextTo: barAnchor.rect, on: barAnchor.screen)
        } else if let screen = NSScreen.underMouse ?? NSScreen.main {
            controls.place(nextTo: screen.visibleFrame, on: screen)
        } else {
            controls.orderFrontRegardless()
        }
    }

    private func hideRecordingPanels() {
        frameOverlay?.orderOut(nil)
        frameOverlay = nil
        controls.onInterrupt = nil
        controls.orderOut(nil)
    }
}
