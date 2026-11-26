import AppKit

final class CaptureCoordinator {
    /// Called with true when a recording begins, and with false when it
    /// ends. The menu bar icon turns into a stop button meanwhile.
    var onRecordingChange: ((Bool) -> Void)?

    private let thumbnailController: ThumbnailController
    private let ensurePermission: @MainActor () -> Bool
    private let playShutterSound: @MainActor () -> Void
    private let makeRecordingSession: @MainActor (CaptureStorage) -> AreaRecordingSession
    private let makeWindowRecordingSession: @MainActor (CaptureStorage) -> WindowRecordingSession
    private var isCapturing = false
    private var recordingSession: (any RecordingSession)?
    private var recordingTask: Task<Void, Never>?

    /// True while a recording runs, including while it prepares.
    var isRecording: Bool { recordingSession?.isRecording == true }

    init(
        thumbnailController: ThumbnailController,
        ensurePermission: @escaping @MainActor () -> Bool = { ScreenRecordingPermission.ensureGranted() },
        playShutterSound: @escaping @MainActor () -> Void = { Preferences.shutterSound().play() },
        makeRecordingSession: @escaping @MainActor (CaptureStorage) -> AreaRecordingSession = {
            AreaRecordingSession(storage: $0)
        },
        makeWindowRecordingSession: @escaping @MainActor (CaptureStorage) -> WindowRecordingSession = {
            WindowRecordingSession(storage: $0)
        }
    ) {
        self.thumbnailController = thumbnailController
        self.ensurePermission = ensurePermission
        self.playShutterSound = playShutterSound
        self.makeRecordingSession = makeRecordingSession
        self.makeWindowRecordingSession = makeWindowRecordingSession
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
            try await Self.selectArea()?.screenshot
        }
    }

    func captureText() {
        runTextCapture {
            try await Self.selectArea()?.screenshot
        }
    }

    /// Area selection first, then the area is recorded while the user
    /// scrolls it, and the frames are joined into one tall picture.
    func captureScrollingArea() {
        run {
            guard let selection = try await Self.selectArea() else {
                return nil
            }
            return try await ScrollCaptureSession().run(selection)
        }
    }

    private static func selectArea() async throws -> AreaSelection? {
        let frozenScreens = try await ScreenCapturer.captureAllDisplays()
        return await AreaSelectionSession().run(with: frozenScreens)
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

    /// The frame first, which starts where the last recording was; pressed
    /// again, recording begins, and once more, it stops. The recording
    /// then joins the screenshots' thumbnails.
    @discardableResult
    func recordArea() -> Task<Void, Never>? {
        if let session = recordingSession as? AreaRecordingSession {
            session.advance()
            return nil
        }
        return startRecording(makeRecordingSession)
    }

    /// Pick a window on screen to begin recording it; pressed again while
    /// recording, it stops. The recording then joins the thumbnails.
    @discardableResult
    func recordWindow() -> Task<Void, Never>? {
        if let session = recordingSession as? WindowRecordingSession {
            session.advance()
            return nil
        }
        return startRecording(makeWindowRecordingSession)
    }

    @discardableResult
    func recordFullscreen() -> Task<Void, Never>? {
        if let session = recordingSession as? FullscreenRecordingSession {
            session.advance()
            return nil
        }
        return startRecording { FullscreenRecordingSession(storage: $0) }
    }

    private func startRecording(
        _ makeSession: @escaping @MainActor (CaptureStorage) -> any RecordingSession
    ) -> Task<Void, Never>? {
        let task = start(onError: {
            ErrorAlert.show($0, title: String(localized: "The recording could not be made"))
        }) { [self] in
            let session = makeSession(thumbnailController.storage)
            session.onRecordingChange = { [weak self] isRecording in
                self?.onRecordingChange?(isRecording)
            }
            recordingSession = session
            defer {
                recordingSession = nil
                recordingTask = nil
            }
            guard let recording = try await session.run() else {
                Log.capture.info("Recording cancelled")
                return
            }
            thumbnailController.show(recording)
        }
        guard let task else { return nil }
        recordingTask = task
        return task
    }

    /// The menu bar icon's stop button.
    func stopRecording() {
        recordingSession?.stop()
    }

    /// Stops the recording, if one is running, and waits until it has
    /// joined the thumbnails.
    func finishRecording() async {
        guard isRecording else { return }
        stopRecording()
        await recordingTask?.value
    }

    /// Shared skeleton of every capture mode that ends in a screenshot.
    /// `capture` returns the screenshot, or nil when the user cancelled.
    /// Returns the task that waits for it, or nil when no capture starts.
    /// Tests pass their own `capture` and wait for the task.
    @discardableResult
    func run(_ capture: @escaping () async throws -> Screenshot?) -> Task<Void, Never>? {
        start(onError: {
            ErrorAlert.show($0, title: String(localized: "The screenshot could not be taken"))
        }) { [self] in
            guard let screenshot = try await capture() else {
                Log.capture.info("Capture cancelled")
                return
            }
            Log.capture.info("Captured \(screenshot.image.width)x\(screenshot.image.height) px")
            playShutterSound()
            thumbnailController.show(screenshot)
        }
    }

    @discardableResult
    func runTextCapture(
        recognize: @escaping (CGImage) async throws -> String? = TextRecognizer.recognize,
        copyText: @escaping (String) -> Bool = { Clipboard.copy(text: $0) },
        showFeedback: @escaping (TextCaptureFeedback) -> Void = { $0.show() },
        _ capture: @escaping () async throws -> Screenshot?
    ) -> Task<Void, Never>? {
        start(onError: { _ in showFeedback(.captureFailed) }) {
            guard let screenshot = try await capture() else { return }
            do {
                guard let text = try await recognize(screenshot.image) else {
                    showFeedback(.noText)
                    return
                }
                showFeedback(copyText(text) ? .copied : .copyFailed)
            } catch {
                Log.capture.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
                showFeedback(.recognitionFailed)
            }
        }
    }

    /// Shared skeleton of every capture mode: one at a time, never under a
    /// dialog, and only with the Screen Recording permission. `capture`
    /// does the work and shows its result.
    private func start(
        onError: @escaping (Error) -> Void,
        _ capture: @escaping () async throws -> Void
    ) -> Task<Void, Never>? {
        guard NSApp.modalWindow == nil else {
            Log.capture.info("Ignored: a modal dialog is open")
            return nil
        }
        guard !isCapturing else {
            Log.capture.info("Ignored: a capture is already running")
            return nil
        }
        // Set before the permission check, which can show an alert. Should a
        // hotkey get through while the alert waits for the user, it must not
        // start a second check, with a second alert on top of the first.
        isCapturing = true
        guard ensurePermission() else {
            isCapturing = false
            Log.capture.info("Stopped: no Screen Recording permission")
            return nil
        }
        Log.capture.info("Capture started")

        return Task {
            defer { isCapturing = false }
            do {
                try await capture()
            } catch {
                Log.capture.error("Capture failed: \(error.localizedDescription, privacy: .public)")
                onError(error)
            }
        }
    }
}
