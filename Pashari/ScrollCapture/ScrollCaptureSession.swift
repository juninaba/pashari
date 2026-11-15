import AppKit
import ScreenCaptureKit

/// The second half of scroll capture, once the area is picked: records the
/// area while the user scrolls its content, until they click Done.
///
/// Unlike the selection overlays, the overlay here lets every click and
/// scroll through to the apps underneath, so that the user can scroll the
/// content as usual. The controls sit in a small panel next to the area.
final class ScrollCaptureSession {
    private enum Ending {
        case done
        case cancelled
        case failed(Error)
    }

    private var overlay: OverlayPanel?
    private var controls: ScrollCaptureControlPanel?
    private var spaceObserver: SpaceChangeObserver?
    private var recorder: ScrollRecorder?
    private var areaSize = CGSize.zero

    private var ending: Ending?
    private var continuation: CheckedContinuation<Ending, Never>?

    /// Returns the joined picture, or nil when the user cancelled.
    func run(_ selection: AreaSelection) async throws -> Screenshot? {
        let screen = selection.frozen.screen
        // ScreenCaptureKit takes the area in points. On a part of a point it
        // would have to scale the frames, which blurs them.
        let area = selection.rect.snappedToPixels(scale: 1)
        guard area.width >= 1, area.height >= 1 else { return nil }
        areaSize = area.size
        let startedAt = Date()

        show(area, on: screen)
        defer { hide() }

        let recorder = try await startRecording(area, on: screen)
        Log.capture.info("Scroll recording started")
        let ending = await waitForEnding()
        self.recorder = nil

        switch ending {
        case .cancelled:
            // Not `stop()`, which would make the picture only for it to be
            // thrown away: a copy of every row, up to a few hundred MB.
            await recorder.cancel()
            return nil
        case .failed(let error):
            // Keep what was recorded until then, if anything.
            guard let image = await recorder.stop() else { throw error }
            return Screenshot(image: image, scale: recorder.scale, capturedAt: startedAt)
        case .done:
            // Without a single frame, the area as it was when picked is the
            // next best thing.
            guard let image = await recorder.stop() else { return selection.screenshot }
            return Screenshot(image: image, scale: recorder.scale, capturedAt: startedAt)
        }
    }

    // MARK: - Recording

    private func startRecording(_ area: CGRect, on screen: NSScreen) async throws -> ScrollRecorder {
        let content = try await shareableContentListingPashari()
        guard
            let displayID = screen.displayID,
            let display = content.displays.first(where: { $0.displayID == displayID })
        else {
            throw CaptureError.displayNotFound
        }

        let recorder = ScrollRecorder(
            area: area,
            of: display,
            filter: ScreenCapturer.recordingFilter(of: display, in: content),
            onProgress: { [weak self] progress in
                Task { @MainActor in self?.update(progress) }
            },
            onFailure: { [weak self] error in
                Task { @MainActor in self?.end(.failed(error)) }
            }
        )
        self.recorder = recorder
        try await recorder.start()
        return recorder
    }

    /// The overlay and the controls must be left out of the recording.
    /// They were only just put on screen and may not be listed yet, which
    /// does not matter as long as Pashari itself is: the recording then
    /// leaves out all its windows but those a screenshot shows. Pashari is
    /// listed once any of its windows is, such as its menu bar icon.
    private func shareableContentListingPashari() async throws -> SCShareableContent {
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var attempts = 1
        while !content.applications.contains(where: { $0.processID == ownProcessID }), attempts < 10 {
            try await Task.sleep(for: .milliseconds(30))
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            attempts += 1
        }
        return content
    }

    private func update(_ progress: ScrollRecorder.Progress) {
        guard ending == nil, let recorder else { return }
        // The first report comes with the first frame: from then on,
        // scrolling adds to the picture.
        controls?.show(
            size: CGSize(width: areaSize.width, height: CGFloat(progress.pictureHeight) / recorder.scale),
            status: progress.isLost ? .lost : .recording
        )
        if progress.isFull {
            Log.capture.info("Scroll capture reached the height limit")
            end(.done)
        }
    }

    // MARK: - Ending

    private func end(_ ending: Ending) {
        guard self.ending == nil else { return }
        self.ending = ending
        controls?.disableButtons()
        continuation?.resume(returning: ending)
        continuation = nil
    }

    /// The user may already have decided while the recording was starting.
    private func waitForEnding() async -> Ending {
        if let ending { return ending }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    // MARK: - Panels

    private func show(_ area: CGRect, on screen: NSScreen) {
        let overlay = OverlayPanel(screen: screen)
        // Every click and scroll goes through to the app underneath.
        overlay.ignoresMouseEvents = true
        overlay.contentView = ScrollCaptureOverlayView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            area: area
        )
        // A dialog that opens meanwhile, such as an error, ends the capture.
        overlay.onCancel = { [weak self] in self?.end(.cancelled) }
        overlay.orderFrontRegardless()
        self.overlay = overlay

        let controls = ScrollCaptureControlPanel()
        controls.onDone = { [weak self] in self?.end(.done) }
        controls.onCancel = { [weak self] in self?.end(.cancelled) }
        controls.show(size: area.size, status: .preparing)
        let areaOnScreen = CGRect(
            x: screen.frame.minX + area.minX,
            y: screen.frame.maxY - area.maxY,
            width: area.width,
            height: area.height
        )
        let controlsFrame = ScrollCaptureControlPanel.frame(
            ofSize: controls.frame.size,
            nextTo: areaOnScreen,
            in: screen.visibleFrame
        )
        controls.setFrame(controlsFrame, display: false)
        controls.orderFrontRegardless()
        // Return and Escape reach it while it holds the keyboard.
        controls.makeKey()
        self.controls = controls

        spaceObserver = SpaceChangeObserver { [weak self] in
            // The app on the new Space has taken the keyboard.
            self?.controls?.makeKey()
        }
    }

    private func hide() {
        spaceObserver?.stop()
        spaceObserver = nil
        overlay?.orderOut(nil)
        overlay = nil
        controls?.orderOut(nil)
        controls = nil
    }
}
