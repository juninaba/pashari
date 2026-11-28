import AppKit
import AVFoundation
import ScreenCaptureKit
import Testing

@testable import Pashari

struct AreaRecorderSizeTests {
    @Test func anAreaIsRecordedInItsOwnPixels() {
        let size = ScreenRecorder.pixelSize(of: CGSize(width: 300, height: 201), scale: 2)

        #expect(size == (width: 600, height: 402))
    }

    @Test func anOddNumberOfPixelsLosesOne() {
        let size = ScreenRecorder.pixelSize(of: CGSize(width: 301, height: 201), scale: 1)

        #expect(size == (width: 300, height: 200))
    }

    @Test func aWholeFiveKDisplayIsRecordedAtTheEncodersLargestSize() {
        let size = ScreenRecorder.pixelSize(of: CGSize(width: 2560, height: 1440), scale: 2)

        #expect(size == (width: 4096, height: 2304))
    }

    @Test func anOddAreaOnAStandardDisplayLosesAColumnRatherThanBeingScaled() {
        let area = CGRect(x: 10, y: 20, width: 17, height: 11)
        let size = ScreenRecorder.pixelSize(of: area.size, scale: 1)

        #expect(ScreenRecorder.sourceRect(of: area, width: size.width, height: size.height, scale: 1)
            == CGRect(x: 10, y: 20, width: 16, height: 10))
        // On a Retina display every point is two pixels, an even number.
        let retina = ScreenRecorder.pixelSize(of: area.size, scale: 2)
        #expect(ScreenRecorder.sourceRect(of: area, width: retina.width, height: retina.height, scale: 2) == area)
        // A whole 5K display is scaled down anyway.
        let wide = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let scaled = ScreenRecorder.pixelSize(of: wide.size, scale: 2)
        #expect(ScreenRecorder.sourceRect(of: wide, width: scaled.width, height: scaled.height, scale: 2) == wide)
    }

    @Test func aTinyAreaStillMakesAVideo() {
        let size = ScreenRecorder.pixelSize(of: CGSize(width: 1, height: 1), scale: 1)

        #expect(size == (width: 2, height: 2))
    }
}

/// These record a real window, so they run only where Pashari has the
/// Screen Recording permission.
@MainActor
@Suite(
    .serialized,
    .enabled(if: CGPreflightScreenCaptureAccess(), "needs the Screen Recording permission"),
    .takesTurnsOnTheScreen
)
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
            size = ScreenRecorder.bytesWritten(to: url)
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
            let onScreen = ColorPage.samples(of: screenshot.image)

            let url = try TestVideos.temporaryURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let events = RecorderEvents()
            let recorder = try await page.makeRecorder(writingTo: url, reportingTo: events)
            try await recorder.start()
            try await events.waitForStart()
            try await Task.sleep(for: .milliseconds(200))
            let duration = try #require(try await recorder.stop())
            let recorded = ColorPage.samples(of: try await TestVideos.image(in: url, at: duration / 2))

            // Within a few levels: at the edge of what the display shows,
            // the screenshot's way to sRGB and the recording's round a
            // little differently (pure green: 5, 199, 1 against 0, 199, 0).
            // In most places: the recording also shows the pointer.
            let matching = zip(recorded, onScreen).filter { $0.isClose(to: $1, within: 6) }
            #expect(matching.count >= 3, "\(color): \(recorded) recorded, \(onScreen) on screen")
        }
    }
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

private extension ColorPage {
    func makeRecorder(writingTo url: URL, reportingTo events: RecorderEvents) async throws -> ScreenRecorder {
        let content = try await listedContent()
        let displayID = try #require(window.screen?.displayID)
        let display = try #require(content.displays.first { $0.displayID == displayID })
        return try ScreenRecorder(
            area: area,
            filter: ScreenCapturer.displayFilter(of: display, in: content),
            url: url,
            onStart: { Task { @MainActor in events.hasStarted = true } },
            onFailure: { error in Task { @MainActor in events.failure = error } }
        )
    }
}
