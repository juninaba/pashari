import AppKit
import AVFoundation
import ScreenCaptureKit
import Testing

@testable import Pashari

struct AreaRecorderSizeTests {
    @Test func anAreaIsRecordedInItsOwnPixels() {
        let size = AreaRecorder.pixelSize(of: CGSize(width: 300, height: 201), scale: 2)

        #expect(size == (width: 600, height: 402))
    }

    @Test func anOddNumberOfPixelsLosesOne() {
        let size = AreaRecorder.pixelSize(of: CGSize(width: 301, height: 201), scale: 1)

        #expect(size == (width: 300, height: 200))
    }

    @Test func aWholeFiveKDisplayIsRecordedAtTheEncodersLargestSize() {
        let size = AreaRecorder.pixelSize(of: CGSize(width: 2560, height: 1440), scale: 2)

        #expect(size == (width: 4096, height: 2304))
    }

    @Test func aTinyAreaStillMakesAVideo() {
        let size = AreaRecorder.pixelSize(of: CGSize(width: 1, height: 1), scale: 1)

        #expect(size == (width: 2, height: 2))
    }
}

/// These record a real window, so they run only where Pashari has the
/// Screen Recording permission.
@MainActor
@Suite(.serialized, .enabled(if: CGPreflightScreenCaptureAccess(), "needs the Screen Recording permission"))
struct AreaRecorderTests {
    @Test func recordingAnAreaMakesAVideoOfWhatHappensThere() async throws {
        let page = try await ColorPage.show(.pageBlue)
        defer { page.close() }
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let events = RecorderEvents()
        let recorder = try await page.makeRecorder(writingTo: url, reportingTo: events)

        try await recorder.start()
        try await events.waitForStart()
        let startedAt = Date()
        try await Task.sleep(for: .milliseconds(400))
        page.fill(.pageRed)
        try await Task.sleep(for: .milliseconds(600))
        let duration = try #require(try await recorder.stop())
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(abs(duration - elapsed) < 0.25, "\(duration) s recorded in \(elapsed) s")
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let scale = page.window.backingScaleFactor
        #expect(
            try await track.load(.naturalSize)
                == CGSize(width: page.area.width * scale, height: page.area.height * scale)
        )
        #expect(page.isShowing(.pageBlue, in: try await TestVideos.image(in: url, at: 0.1)))
        #expect(page.isShowing(.pageRed, in: try await TestVideos.image(in: url, at: duration - 0.05)))
    }

    @Test func theFileGrowsWhileRecording() async throws {
        let page = try await ColorPage.show(.pageBlue)
        defer { page.close() }
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let events = RecorderEvents()
        let recorder = try await page.makeRecorder(writingTo: url, reportingTo: events)

        try await recorder.start()
        try await events.waitForStart()
        var size = 0
        for step in 0..<50 where size == 0 {
            page.fill(step.isMultiple(of: 2) ? .pageRed : .pageBlue)
            try await Task.sleep(for: .milliseconds(50))
            size = AreaRecorder.bytesWritten(to: url)
        }
        _ = try await recorder.stop()

        #expect(size > 0)
    }

    @Test func pasharisPanelsThatOpenWhileRecordingStayOutOfIt() async throws {
        let page = try await ColorPage.show(.pageBlue)
        defer { page.close() }
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let events = RecorderEvents()
        let recorder = try await page.makeRecorder(writingTo: url, reportingTo: events)

        try await recorder.start()
        try await events.waitForStart()
        // Over the page, like the recording's bar when there is no room
        // beside the area, and on screen too late to be listed when the
        // recording began.
        let cover = try await Cover.show(over: page.window.frame)
        defer { cover.orderOut(nil) }
        page.fill(.pageBlue)
        try await Task.sleep(for: .milliseconds(500))
        let duration = try #require(try await recorder.stop())

        #expect(page.isShowing(.pageBlue, in: try await TestVideos.image(in: url, at: duration - 0.05)))
    }

    @Test func aRecordingShowsTheColoursAScreenshotShows() async throws {
        let page = try await ColorPage.show(.pageBlue)
        defer { page.close() }
        let screen = try #require(page.window.screen)
        // The purest blue and green as well, which this display, like many,
        // shows a little differently from sRGB.
        let colors: [TestImages.RGBA] = [
            .pageBlue, .pageRed, .blue, .red,
            TestImages.RGBA(red: 0, green: 200, blue: 0, alpha: 255),
            TestImages.RGBA(red: 30, green: 30, blue: 30, alpha: 255),
            TestImages.RGBA(red: 230, green: 180, blue: 150, alpha: 255),
        ]
        for color in colors {
            page.fill(color)
            try await Task.sleep(for: .milliseconds(100))
            let screenshot = try #require(try await ScreenCapturer.captureDisplay(screen).cropped(to: page.area))
            let onScreen = TestImages.pixel(of: screenshot.image, x: screenshot.image.width / 2, y: screenshot.image.height / 2)

            let url = try TestVideos.temporaryURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let events = RecorderEvents()
            let recorder = try await page.makeRecorder(writingTo: url, reportingTo: events)
            try await recorder.start()
            try await events.waitForStart()
            try await Task.sleep(for: .milliseconds(200))
            let duration = try #require(try await recorder.stop())
            let frame = try await TestVideos.image(in: url, at: duration / 2)
            let recorded = TestImages.pixel(of: frame, x: frame.width / 2, y: frame.height / 2)

            // Within a few levels: at the edge of what the display shows,
            // the screenshot's way to sRGB and the recording's round a
            // little differently (pure green: 5, 199, 1 against 0, 199, 0).
            let channels = [
                (recorded.red, onScreen.red), (recorded.green, onScreen.green), (recorded.blue, onScreen.blue),
            ]
            #expect(channels.allSatisfy { abs(Int($0) - Int($1)) <= 6 }, "\(color): \(recorded) recorded, \(onScreen) on screen")
        }
    }
}

private extension TestImages.RGBA {
    /// Colours this display shows as they are, unlike the purest blue.
    static let pageBlue = TestImages.RGBA(red: 40, green: 90, blue: 200, alpha: 255)
    static let pageRed = TestImages.RGBA(red: 200, green: 60, blue: 40, alpha: 255)
}

@MainActor
private final class RecorderEvents {
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

/// A window of one colour above other apps' windows, away from the pointer,
/// which the recording would show.
@MainActor
private final class ColorPage {
    static let size = CGSize(width: 240, height: 160)

    let window: NSWindow

    /// The whole window, in points from the top-left corner of its display.
    var area: CGRect {
        let screen = window.screen!.frame
        return CGRect(
            x: window.frame.minX - screen.minX,
            y: screen.maxY - window.frame.maxY,
            width: window.frame.width,
            height: window.frame.height
        )
    }

    private init(window: NSWindow) {
        self.window = window
    }

    static func show(_ color: TestImages.RGBA) async throws -> ColorPage {
        let screen = try #require(NSScreen.main)
        let visible = screen.visibleFrame
        // On the right, clear of the scroll capture tests' page at the top
        // left, which may be on screen at the same time, and of the pointer.
        let pointerIsLow = NSEvent.mouseLocation.y < visible.midY
        let y = pointerIsLow ? visible.maxY - 80 - size.height : visible.minY + 80
        let window = NSWindow(
            contentRect: CGRect(
                x: (visible.maxX - 80 - size.width).rounded(),
                y: y.rounded(),
                width: size.width,
                height: size.height
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // Without the fade-in, which the first frames would catch halfway.
        window.animationBehavior = .none
        // Above ordinary windows, but not on a level whose windows of
        // Pashari's are left out of recordings.
        window.level = .modalPanel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSView()
        window.contentView?.wantsLayer = true
        let page = ColorPage(window: window)
        page.fill(color)
        window.orderFrontRegardless()
        try await waitUntilOnScreen(window)
        return page
    }

    func fill(_ color: TestImages.RGBA) {
        window.contentView?.layer?.backgroundColor = CGColor(
            srgbRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        )
        window.displayIfNeeded()
    }

    /// Whether the middle of `image`, a frame of the recording, shows `color`.
    func isShowing(_ color: TestImages.RGBA, in image: CGImage) -> Bool {
        let pixel = TestImages.pixel(of: image, x: image.width / 2, y: image.height / 2)
        return [(pixel.red, color.red), (pixel.green, color.green), (pixel.blue, color.blue)]
            .allSatisfy { abs(Int($0) - Int($1)) <= 12 }
    }

    func makeRecorder(writingTo url: URL, reportingTo events: RecorderEvents) async throws -> AreaRecorder {
        let content = try await shareableContentListingThePage()
        let displayID = try #require(window.screen?.displayID)
        let display = try #require(content.displays.first { $0.displayID == displayID })
        return try AreaRecorder(
            area: area,
            filter: ScreenCapturer.recordingFilter(of: display, in: content),
            url: url,
            onStart: { Task { @MainActor in events.hasStarted = true } },
            onFailure: { error in Task { @MainActor in events.failure = error } }
        )
    }

    /// The recording leaves out the windows of Pashari's, the test host,
    /// that were not listed when it began: the page must be by then.
    private func shareableContentListingThePage() async throws -> SCShareableContent {
        let id = CGWindowID(window.windowNumber)
        for _ in 0..<50 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if content.windows.contains(where: { $0.windowID == id }) {
                return content
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("The test window was never listed")
        return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    func close() {
        window.orderOut(nil)
    }
}
