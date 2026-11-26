import AppKit
import AVFoundation
import ScreenCaptureKit
import Testing

@testable import Pashari

@MainActor
@Suite(.serialized, .takesTurnsOnTheScreen)
struct WindowRecordingCursorAndModalTests {
    @Test func videoCameraCursorIsDrawnSharplyWithItsHotSpotInTheMiddle() {
        let cursor = NSCursor.videoCamera
        let size = NSCursor.cameraCursorSize

        #expect(cursor !== NSCursor.arrow)
        #expect(cursor !== NSCursor.camera)
        #expect(cursor.image.size == size)
        #expect(cursor.hotSpot == NSPoint(x: size.width / 2, y: size.height / 2))
        let pixelWidths = cursor.image.representations.map(\.pixelsWide).sorted()
        #expect(pixelWidths == [Int(size.width), Int(size.width) * 2])
    }

    @Test func modalPresentationInterruptsAVisibleRecordingControlPanel() throws {
        let panel = RecordingControlPanel()
        panel.show(.recording(elapsed: 3, bytes: 1024))
        panel.setFrameOrigin(CGPoint(x: 100, y: 100))
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        try #require(panel.isVisible)

        var interruptions = 0
        panel.onInterrupt = { interruptions += 1 }

        let response = ModalPresentation.run {
            #expect(interruptions == 1)
            return .alertFirstButtonReturn
        }

        #expect(response == .alertFirstButtonReturn)
    }

    @Test func windowExistsReportsFalseForMissingWindowIDs() async throws {
        #expect(!ScreenCapturer.windowExists(kCGNullWindowID))
        #expect(!ScreenCapturer.windowExists(CGWindowID.max))
        let page = try await ColorPage.show(.pageBlue)
        defer { page.close() }
        #expect(ScreenCapturer.windowExists(CGWindowID(page.window.windowNumber)))
    }
    @Test func cancellingMicrophonePermissionBeforeWindowRecordingStartsAbortsCleanly() async throws {
        let storage = try TestStorage()
        defer { storage.remove() }
        var resolved = 0
        let session = WindowRecordingSession(
            storage: storage.storage,
            chooseWindow: { nil },
            audio: { RecordingAudio(systemAudio: false, microphone: true) },
            resolveMicrophonePermission: {
                resolved += 1
                return .cancel
            }
        )

        #expect(try await session.run() == nil)
        // Permission is only resolved after a window is actually picked.
        #expect(resolved == 0)
    }
}

/// Real-screen window recording tests, which run only where Pashari has the
/// Screen Recording permission.
@MainActor
@Suite(
    .serialized,
    .enabled(if: CGPreflightScreenCaptureAccess(), "needs the Screen Recording permission"),
    .takesTurnsOnTheScreen
)
struct WindowRecordingTests {
    @Test func recordingAWindowCapturesItAloneAndFollowsMoveAndResize() async throws {
        let page = try await ColorPage.show(.pageBlue)
        defer { page.close() }
        let scWindow = try await page.scWindow()
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let events = WindowRecorderEvents()
        let recorder = try ScreenRecorder(
            window: scWindow,
            url: url,
            onStart: { Task { @MainActor in events.hasStarted = true } },
            onFailure: { error in Task { @MainActor in events.failure = error } }
        )

        try await recorder.start()
        try await events.waitForStart()
        // Cover the window completely with an opaque red panel. Because the
        // window is captured on its own, the cover must not appear.
        let cover = try await Cover.show(over: page.window.frame)
        defer { cover.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(350))
        let coveredTime = 0.25

        // Move and resize the window, and change its colour underneath the cover.
        let moved = page.window.frame.offsetBy(dx: -40, dy: -20)
        page.window.setFrame(CGRect(origin: moved.origin, size: CGSize(width: 320, height: 140)), display: true)
        page.fill(.pageRed)
        try await Task.sleep(for: .milliseconds(450))
        let duration = try #require(try await recorder.stop())

        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let scale = page.window.backingScaleFactor
        #expect(
            try await track.load(.naturalSize)
                == CGSize(width: ColorPage.size.width * scale, height: ColorPage.size.height * scale)
        )
        // Before the change: blue, not the red cover.
        #expect(page.isShowing(.pageBlue, in: try await TestVideos.image(in: url, at: coveredTime)))
        // After moving and resizing: the centre of the letterboxed frame shows red.
        let afterResize = try await TestVideos.image(in: url, at: duration - 0.05)
        let center = TestImages.pixel(of: afterResize, x: afterResize.width / 2, y: afterResize.height / 2)
        #expect(center.isClose(to: .pageRed, within: 12), "got \(center)")
    }

    @Test func aWindowRecordingShowsTheColoursAScreenshotShows() async throws {
        let page = try await ColorPage.show(.pageBlue)
        defer { page.close() }
        let scWindow = try await page.scWindow()
        let screenshot = try await ScreenCapturer.captureWindow(scWindow)
        let onScreen = ColorPage.samples(of: screenshot.image)

        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let events = WindowRecorderEvents()
        let recorder = try ScreenRecorder(
            window: scWindow,
            url: url,
            onStart: { Task { @MainActor in events.hasStarted = true } },
            onFailure: { error in Task { @MainActor in events.failure = error } }
        )

        try await recorder.start()
        try await events.waitForStart()
        try await Task.sleep(for: .milliseconds(250))
        let duration = try #require(try await recorder.stop())
        let recorded = ColorPage.samples(of: try await TestVideos.image(in: url, at: duration / 2))

        let matching = zip(recorded, onScreen).filter { $0.isClose(to: $1, within: 6) }
        #expect(matching.count >= 3, "\(recorded) recorded, \(onScreen) on screen")
    }

    @Test func cancellingWindowSelectionRecordsNothing() async throws {
        let storage = try TestStorage()
        defer { storage.remove() }
        let session = WindowRecordingSession(
            storage: storage.storage,
            chooseWindow: { nil }
        )
        var changes: [Bool] = []
        session.onRecordingChange = { changes.append($0) }

        #expect(try await session.run() == nil)
        #expect(changes.isEmpty)
        #expect(!NSApp.windows.contains { ($0 is RecordingControlPanel || $0 is OverlayPanel) && $0.isVisible })
    }

    @Test func theWindowSelectionOverlayUsesTheVideoCameraCursorAndCancelsWithEscape() async throws {
        let page = try await ColorPage.show(.pageBlue)
        defer { page.close() }
        let scWindow = try await page.scWindow()
        let selection = WindowSelectionSession(cursor: .videoCamera)
        let run = Task { await selection.run(with: [scWindow])?.windowID }

        let view = try await waitForTheWindowOverlay()
        #expect(view.cursor === NSCursor.videoCamera)
        view.keyDown(with: try #require(escape(in: view.window)))

        #expect(await run.value == nil)
        #expect(!NSApp.windows.contains { $0 is OverlayPanel && $0.isVisible })
    }

    @Test func recordingAWindowThroughTheCoordinatorJoinsTheThumbnailsAndStopsWithTheHotkey() async throws {
        let page = try await ColorPage.show(.pageBlue)
        defer { page.close() }
        let scWindow = try await page.scWindow()
        let storage = try TestStorage()
        defer { storage.remove() }
        let thumbnails = ThumbnailController(storage: storage.storage)
        defer {
            while let card = thumbnails.cards.first { card.onClose?() }
        }
        let coordinator = CaptureCoordinator(
            thumbnailController: thumbnails,
            ensurePermission: { true },
            makeWindowRecordingSession: { storage in
                WindowRecordingSession(storage: storage, chooseWindow: { scWindow })
            }
        )
        var changes: [Bool] = []
        coordinator.onRecordingChange = { changes.append($0) }

        let run = try #require(coordinator.recordWindow())
        let bar = try await waitForTheBar { if case .recording = $0 { true } else { false } }
        #expect(changes == [true])
        #expect(!bar.isKeyWindow)
        // Window recording leaves no dimming overlay over the screen.
        #expect(!NSApp.windows.contains { $0 is OverlayPanel && $0.isVisible })
        // Other modes are ignored while recording a window.
        #expect(coordinator.recordArea() == nil)
        #expect(coordinator.run { nil } == nil)
        page.fill(.pageRed)
        try await Task.sleep(for: .milliseconds(400))
        // Pressing the Record Window hotkey again stops the recording.
        coordinator.recordWindow()
        await run.value

        #expect(changes == [true, false])
        #expect(thumbnails.pendingCount == 1)
        #expect(thumbnails.cards.first?.duration != nil)
        #expect(!NSApp.windows.contains { ($0 is RecordingControlPanel || $0 is OverlayPanel) && $0.isVisible })
    }

    @Test func aDialogEndsAWindowRecordingWhenItOpensNotWhenItCloses() async throws {
        let page = try await ColorPage.show(.pageBlue)
        defer { page.close() }
        let scWindow = try await page.scWindow()
        let storage = try TestStorage()
        defer { storage.remove() }
        let session = WindowRecordingSession(storage: storage.storage, chooseWindow: { scWindow })
        let run = Task { try await session.run() }

        _ = try await waitForTheBar { if case .recording = $0 { true } else { false } }
        try await Task.sleep(for: .milliseconds(400))
        ModalPresentation.run {
            usleep(1_500_000)
            return .alertFirstButtonReturn
        }

        let recording = try #require(try await run.value)
        #expect(FileManager.default.fileExists(atPath: recording.url.path))
        #expect(recording.duration < 1.2, "\(recording.duration) s recorded")
    }

    @Test func closingARetainedWindowEndsTheRecordingAndKeepsWhatWasRecorded() async throws {
        // ColorPage sets `isReleasedWhenClosed = false` like Settings, so its
        // CGWindowID stays on the window server after `close()`.
        let page = try await ColorPage.show(.pageBlue)
        defer { page.close() }
        let scWindow = try await page.scWindow()
        let storage = try TestStorage()
        defer { storage.remove() }
        let session = WindowRecordingSession(
            storage: storage.storage,
            chooseWindow: { scWindow }
        )
        let run = Task { try await session.run() }

        _ = try await waitForTheBar { if case .recording = $0 { true } else { false } }
        try await Task.sleep(for: .milliseconds(350))
        page.window.close()

        let recording = try #require(try await run.value)
        #expect(recording.duration > 0.25 && recording.duration < 2)
        #expect(FileManager.default.fileExists(atPath: recording.url.path))
        #expect(page.isShowing(.pageBlue, in: try await TestVideos.image(in: recording.url, at: recording.duration / 2)))
    }

    @Test func draggingAWindowPartiallyOffScreenDoesNotClipTheRecording() async throws {
        let page = try await ColorPage.show(.pageBlue)
        defer { page.close() }
        let screen = try #require(page.window.screen)
        let scWindow = try await page.scWindow()
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let events = WindowRecorderEvents()
        let recorder = try ScreenRecorder(
            window: scWindow,
            url: url,
            onStart: { Task { @MainActor in events.hasStarted = true } },
            onFailure: { error in Task { @MainActor in events.failure = error } }
        )

        try await recorder.start()
        try await events.waitForStart()
        // Move the right half of the window past the right edge of the display.
        let halfOffScreen = CGPoint(
            x: (screen.frame.maxX - page.window.frame.width / 2).rounded(),
            y: page.window.frame.minY
        )
        page.window.setFrameOrigin(halfOffScreen)
        page.fill(.pageRed)
        try await Task.sleep(for: .milliseconds(450))
        let duration = try #require(try await recorder.stop())

        let frame = try await TestVideos.image(in: url, at: duration - 0.05)
        // Sample inside the right half that extended off the display edge.
        let offScreenSide = TestImages.pixel(of: frame, x: Int(Double(frame.width) * 0.8), y: frame.height / 2)
        #expect(offScreenSide.isClose(to: .pageRed, within: 12), "got \(offScreenSide)")
    }

    @Test func aRecordingThatNeverReceivesAFirstFrameStopsAfterThePreparingTimeout() async throws {
        let page = try await ColorPage.show(.pageBlue)
        defer { page.close() }
        let scWindow = try await page.scWindow()
        // Hide the window before the stream starts so ScreenCaptureKit suspends
        // immediately without delivering a first frame.
        page.window.orderOut(nil)
        let storage = try TestStorage()
        defer { storage.remove() }
        let runner = RecordingRunner(preparingTimeout: 0.4)

        let started = Date()
        let recording = try await runner.record(
            storage: storage.storage,
            barAnchor: nil,
            makeRecorder: { url, onStart, onFailure in
                try ScreenRecorder(window: scWindow, url: url, onStart: onStart, onFailure: onFailure)
            }
        )
        let elapsed = Date().timeIntervalSince(started)

        #expect(recording == nil)
        #expect(elapsed < 2, "took \(elapsed) s")
        #expect(!NSApp.windows.contains { $0 is RecordingControlPanel && $0.isVisible })
    }

    @Test func recordingEndsWhenWindowExistsReportsTheWindowIsGone() async throws {
        let page = try await ColorPage.show(.pageBlue)
        defer { page.close() }
        let scWindow = try await page.scWindow()
        let storage = try TestStorage()
        defer { storage.remove() }
        var windowStillOpen = true
        let session = WindowRecordingSession(
            storage: storage.storage,
            chooseWindow: { scWindow },
            windowExists: { _ in windowStillOpen }
        )
        let run = Task { try await session.run() }

        _ = try await waitForTheBar { if case .recording = $0 { true } else { false } }
        try await Task.sleep(for: .milliseconds(350))
        windowStillOpen = false

        let recording = try #require(try await run.value)
        #expect(recording.duration > 0.25 && recording.duration < 2)
        #expect(FileManager.default.fileExists(atPath: recording.url.path))
        #expect(page.isShowing(.pageBlue, in: try await TestVideos.image(in: recording.url, at: recording.duration / 2)))
    }

    @Test func quittingWhileRecordingAWindowEndsItAndJoinsTheThumbnailsBeforeTheQuestion() async throws {
        let page = try await ColorPage.show(.pageBlue)
        defer { page.close() }
        let scWindow = try await page.scWindow()
        let storage = try TestStorage()
        defer { storage.remove() }
        let thumbnails = ThumbnailController(storage: storage.storage)
        defer {
            while let card = thumbnails.cards.first { card.onClose?() }
        }
        let delegate = AppDelegate(thumbnailController: thumbnails) { thumbnails in
            CaptureCoordinator(
                thumbnailController: thumbnails,
                ensurePermission: { true },
                makeWindowRecordingSession: { storage in
                    WindowRecordingSession(storage: storage, chooseWindow: { scWindow })
                }
            )
        }
        var questions = 0
        delegate.confirmQuit = {
            questions += 1
            return false
        }
        var replies: [Bool] = []
        delegate.replyToQuit = { replies.append($0) }

        delegate.captureCoordinator.recordWindow()
        _ = try await waitForTheBar { if case .recording = $0 { true } else { false } }
        // Regression check: triggering another recording mode must not lose
        // track of the running recording task before quit.
        #expect(delegate.captureCoordinator.recordArea() == nil)
        try await Task.sleep(for: .milliseconds(300))

        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateLater)
        for _ in 0..<150 where replies.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(replies == [false])
        #expect(questions == 1)
        #expect(!delegate.captureCoordinator.isRecording)
        #expect(thumbnails.pendingCount == 1)
    }
}

@MainActor
private final class WindowRecorderEvents {
    var hasStarted = false
    var failure: Error?

    func waitForStart() async throws {
        for _ in 0..<100 {
            if let failure { throw failure }
            if hasStarted { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("The recording never started")
    }
}

private extension ColorPage {
    func scWindow() async throws -> SCWindow {
        let content = try await listedContent()
        let id = CGWindowID(window.windowNumber)
        return try #require(content.windows.first { $0.windowID == id })
    }
}

@MainActor
private func waitForTheWindowOverlay() async throws -> WindowSelectionView {
    for _ in 0..<100 {
        let views = NSApp.windows.compactMap { $0 as? OverlayPanel }
            .filter(\.isVisible)
            .compactMap { $0.contentView as? WindowSelectionView }
        if let view = views.first {
            return view
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw CocoaError(.featureUnsupported)
}
