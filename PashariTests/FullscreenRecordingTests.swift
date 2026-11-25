import AppKit
import AVFoundation
import Testing

@testable import Pashari

@MainActor
@Suite(
    .enabled(if: CGPreflightScreenCaptureAccess(), "needs the Screen Recording permission"),
    .takesTurnsOnTheScreen
)
struct FullscreenRecordingTests {
    @Test func recordingTheWholeDisplayHidesTheBarAndJoinsTheThumbnails() async throws {
        let page = try await ColorPage.show(.pageBlue)
        defer { page.close() }
        _ = try await page.listedContent()

        let storage = try TestStorage()
        defer { storage.remove() }
        let thumbnails = ThumbnailController(storage: storage.storage)
        defer {
            while let card = thumbnails.cards.first { card.onClose?() }
        }
        let coordinator = CaptureCoordinator(thumbnailController: thumbnails, ensurePermission: { true })
        var changes: [Bool] = []
        coordinator.onRecordingChange = { changes.append($0) }

        let screen = try #require(NSScreen.underMouse ?? NSScreen.main)
        let run = try #require(coordinator.recordFullscreen())
        defer { coordinator.stopRecording() }
        let bar = try await waitForTheBar { if case .recording = $0 { true } else { false } }
        #expect(changes == [true])
        #expect(bar.screen?.displayID == screen.displayID)
        #expect(!NSApp.windows.contains { $0 is OverlayPanel && $0.isVisible })
        #expect(coordinator.recordArea() == nil)

        // Read the color directly behind the visible Stop bar in the MP4.
        let barCenter = CGPoint(x: bar.frame.midX, y: bar.frame.midY)
        page.window.setFrameOrigin(CGPoint(
            x: barCenter.x - page.window.frame.width / 2,
            y: barCenter.y - page.window.frame.height / 2
        ))
        page.fill(.pageRed)
        try await Task.sleep(for: .milliseconds(400))
        #expect(coordinator.recordFullscreen() == nil)
        await run.value

        #expect(changes == [true, false])
        #expect(!bar.isVisible)
        #expect(thumbnails.pendingCount == 1)
        var played: Recording?
        thumbnails.onPlay = { played = $0 }
        let play = try #require(thumbnails.cards.first?.onPlay)
        play()
        let recording = try #require(played)
        #expect(recording.url.pathExtension == "mp4")
        #expect(recording.pointSize == screen.frame.size)

        let frame = try await TestVideos.image(in: recording.url, at: recording.duration - 0.05)
        let size = ScreenRecorder.pixelSize(of: screen.frame.size, scale: screen.backingScaleFactor)
        #expect(frame.width == size.width)
        #expect(frame.height == size.height)
        let scaleX = CGFloat(frame.width) / screen.frame.width
        let scaleY = CGFloat(frame.height) / screen.frame.height
        let patch = try #require(frame.cropping(to: CGRect(
            x: (barCenter.x - screen.frame.minX - 30) * scaleX,
            y: (screen.frame.maxY - barCenter.y - 10) * scaleY,
            width: 60 * scaleX,
            height: 20 * scaleY
        ).integral))
        #expect(page.isShowing(.pageRed, in: patch))
    }
}
