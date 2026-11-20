import AppKit
import ScreenCaptureKit

/// The area to record: in points, with the origin at the top-left corner
/// of `screen`.
struct RecordingArea {
    let screen: NSScreen
    let rect: CGRect
}

/// Record Area, from start to end. First the user draws and adjusts a
/// frame on the live screen, starting from the area recorded last; Record
/// or Return begins recording that area, and Stop ends it.
///
/// While recording, every click, scroll and key goes to the apps
/// underneath: the frame's overlay lets them through, and the bar never
/// takes the keyboard.
final class AreaRecordingSession {
    private enum Phase {
        case choosing
        case recording
        case ended
    }

    private enum Ending {
        case done
        /// A dialog opened, such as an error, and needs the user now.
        case interrupted
        case failed(Error)
    }

    /// Called with true when recording begins, and with false when it ends.
    var onRecordingChange: ((Bool) -> Void)?

    private let storage: CaptureStorage
    private let rememberArea: @MainActor (RecordingArea) -> Void
    private var phase = Phase.choosing
    private let controls = RecordingControlPanel()

    // While choosing.
    private var editor: RecordingFrameEditor
    private var overlays: [(panel: OverlayPanel, view: RecordingAreaView, screen: NSScreen)] = []
    private var choice: CheckedContinuation<RecordingArea?, Never>?
    private var spaceObserver: SpaceChangeObserver?

    // While recording.
    private var frameOverlay: OverlayPanel?
    private var recordingURL: URL?
    private var startedAt: Date?
    private var timer: Timer?
    private var ending: Ending?
    private var endingContinuation: CheckedContinuation<Ending, Never>?

    /// `remembered` is the area recorded last; the frame starts there if
    /// that display is still connected and the area still fits on it.
    /// `rememberArea` keeps the area for next time once recording begins.
    init(
        storage: CaptureStorage,
        remembered: (displayID: CGDirectDisplayID, rect: CGRect)? = Preferences.recordingArea(),
        rememberArea: @escaping @MainActor (RecordingArea) -> Void = { area in
            if let displayID = area.screen.displayID {
                Preferences.setRecordingArea(area.rect, onDisplay: displayID)
            }
        }
    ) {
        self.storage = storage
        self.rememberArea = rememberArea
        let screens = NSScreen.screens
        if
            let remembered,
            let index = screens.firstIndex(where: { $0.displayID == remembered.displayID }),
            CGRect(origin: .zero, size: screens[index].frame.size).contains(remembered.rect),
            RecordingFrameEditor.isLargeEnough(remembered.rect)
        {
            editor = RecordingFrameEditor(frame: .init(screen: index, rect: remembered.rect))
        } else {
            editor = RecordingFrameEditor()
        }
    }

    /// Returns the recording, or nil when the user cancelled before
    /// recording began, or nothing was recorded.
    func run() async throws -> Recording? {
        guard let area = await choose() else { return nil }
        rememberArea(area)
        return try await record(area)
    }

    /// The hotkey again: begins recording while the frame is adjusted, and
    /// stops while recording.
    func advance() {
        switch phase {
        case .choosing: confirm()
        case .recording: stop()
        case .ended: break
        }
    }

    func stop() {
        end(.done)
    }

    // MARK: - Choosing the frame

    private func choose() async -> RecordingArea? {
        await withCheckedContinuation { continuation in
            choice = continuation
            showOverlays()
        }
    }

    private func showOverlays() {
        for (index, screen) in NSScreen.screens.enumerated() {
            let panel = OverlayPanel(screen: screen)
            let bounds = CGRect(origin: .zero, size: screen.frame.size)
            let view = RecordingAreaView(frame: bounds)
            view.autoresizingMask = [.width, .height]
            view.region = { [weak self] point in
                self?.editor.region(at: point, on: index) ?? .outside
            }
            view.onMouseDown = { [weak self] point in
                self?.editor.begin(at: point, on: index, in: bounds)
                self?.showFrame()
            }
            view.onMouseDragged = { [weak self] point in
                self?.editor.move(to: point)
                self?.showFrame()
            }
            view.onMouseUp = { [weak self] in
                self?.editor.end()
                self?.showFrame()
            }
            view.onRecord = { [weak self] in self?.confirm() }
            view.onCancel = { [weak self] in self?.finishChoosing(with: nil) }
            // A dialog that opens meanwhile ends the session too (see
            // `ModalPresentation`).
            panel.onCancel = view.onCancel
            panel.contentView = view
            panel.makeFirstResponder(view)
            panel.orderFrontRegardless()
            overlays.append((panel, view, screen))
        }

        controls.onRecord = { [weak self] in self?.confirm() }
        controls.onCancel = { [weak self] in self?.finishChoosing(with: nil) }
        showFrame()
        OverlayPanel.focus(overlays.map(\.panel))
        spaceObserver = SpaceChangeObserver { [weak self] in
            // The app on the new Space has taken the keyboard. Take it
            // back, so that Return and Escape still work.
            guard let self, choice != nil else { return }
            OverlayPanel.focus(overlays.map(\.panel))
        }
        Log.selection.info("Recording area overlay shown on \(self.overlays.count) screen(s)")
    }

    /// Draws the frame on its screen, and puts the bar next to it.
    private func showFrame() {
        for (index, overlay) in overlays.enumerated() {
            overlay.view.frameRect = editor.frame?.screen == index ? editor.frame?.rect : nil
        }
        guard let frame = editor.frame else {
            controls.orderOut(nil)
            return
        }
        controls.show(.adjusting(frame.rect.size))
        place(controls, nextTo: frame.rect, on: overlays[frame.screen].screen)
    }

    private func confirm() {
        guard
            choice != nil,
            !editor.isDragging,
            let frame = editor.frame,
            RecordingFrameEditor.isLargeEnough(frame.rect)
        else { return }
        finishChoosing(with: RecordingArea(screen: overlays[frame.screen].screen, rect: frame.rect))
    }

    private func finishChoosing(with area: RecordingArea?) {
        // A continuation must be resumed exactly once.
        guard let choice else { return }
        self.choice = nil
        Log.selection.info("Recording area \(area == nil ? "cancelled" : "chosen", privacy: .public)")

        spaceObserver?.stop()
        spaceObserver = nil
        // The overlay held the keyboard. Once it is gone, the keyboard is
        // back with the app the user was working in.
        overlays.forEach { $0.panel.orderOut(nil) }
        overlays.removeAll()
        if area == nil {
            controls.orderOut(nil)
        }
        NSCursor.arrow.set()
        choice.resume(returning: area)
    }

    // MARK: - Recording

    private func record(_ area: RecordingArea) async throws -> Recording? {
        phase = .recording
        onRecordingChange?(true)
        defer {
            phase = .ended
            hideRecordingPanels()
            onRecordingChange?(false)
        }
        showRecordingPanels(area)

        let capturedAt = Date()
        let folder = try storage.makeCaptureDirectory()
        let url = folder.appending(path: ScreenshotWriter.fileName(capturedAt: capturedAt, pathExtension: "mp4"))
        recordingURL = url
        let recorder: AreaRecorder
        do {
            recorder = try await startRecorder(area, writingTo: url)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        Log.capture.info("Area recording started")

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
        Log.capture.info("Area recording ended after \(duration, format: .fixed(precision: 1)) s")
        return Recording(url: url, pointSize: area.rect.size, duration: duration, capturedAt: capturedAt)
    }

    /// The bar and the frame must be left out of the recording. See
    /// `ScreenCapturer.shareableContentListingPashari`.
    private func startRecorder(_ area: RecordingArea, writingTo url: URL) async throws -> AreaRecorder {
        let content = try await ScreenCapturer.shareableContentListingPashari()
        guard
            let displayID = area.screen.displayID,
            let display = content.displays.first(where: { $0.displayID == displayID })
        else {
            throw CaptureError.displayNotFound
        }
        let recorder = try AreaRecorder(
            area: area.rect,
            filter: ScreenCapturer.recordingFilter(of: display, in: content),
            url: url,
            onStart: { [weak self] in
                Task { @MainActor in self?.didStartRecording() }
            },
            onFailure: { [weak self] error in
                Task { @MainActor in self?.end(.failed(error)) }
            }
        )
        try await recorder.start()
        return recorder
    }

    private func didStartRecording() {
        guard ending == nil, startedAt == nil else { return }
        startedAt = Date()
        showProgress()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.showProgress() }
        }
        // Also while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func showProgress() {
        guard ending == nil, let startedAt, let recordingURL else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= RecordingWriter.maximumDuration.seconds {
            Log.capture.info("Area recording reached its longest")
            end(.done)
            return
        }
        controls.show(.recording(elapsed: elapsed, bytes: AreaRecorder.bytesWritten(to: recordingURL)))
    }

    private func end(_ ending: Ending) {
        guard phase == .recording, self.ending == nil else { return }
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

    private func showRecordingPanels(_ area: RecordingArea) {
        let screen = area.screen
        let overlay = OverlayPanel(screen: screen)
        // Every click and scroll goes through to the app underneath.
        overlay.ignoresMouseEvents = true
        overlay.contentView = RecordedAreaOverlayView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            area: area.rect
        )
        // A dialog that opens meanwhile, such as an error, ends the
        // recording, and keeps what was recorded (see `ModalPresentation`).
        overlay.onCancel = { [weak self] in self?.end(.interrupted) }
        overlay.orderFrontRegardless()
        frameOverlay = overlay

        controls.onStop = { [weak self] in self?.stop() }
        controls.show(.preparing)
        place(controls, nextTo: area.rect, on: screen)
        // Over the dimming of the overlay, which came on screen after it.
        controls.orderFrontRegardless()
    }

    private func hideRecordingPanels() {
        frameOverlay?.orderOut(nil)
        frameOverlay = nil
        controls.orderOut(nil)
    }

    /// `rect` is in points from the top-left corner of `screen`.
    private func place(_ controls: RecordingControlPanel, nextTo rect: CGRect, on screen: NSScreen) {
        let onScreen = CGRect(
            x: screen.frame.minX + rect.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        let frame = ControlBarPlacement.frame(ofSize: controls.frame.size, nextTo: onScreen, in: screen.visibleFrame)
        controls.setFrame(frame, display: false)
        if !controls.isVisible {
            controls.orderFrontRegardless()
        }
    }
}
