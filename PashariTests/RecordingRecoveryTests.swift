import AppKit
import AVFoundation
import Testing

@testable import Pashari

@MainActor
struct RecordingRecoveryTests {
    @Test func aFinishedRecordingSaysHowLargeAndHowLongItIs() async throws {
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await TestVideos.makeMP4(at: url, width: 320, height: 200, frames: [(.blue, 0), (.red, 1)], end: 2.5)

        let info = try #require(RecordingFileInfo(contentsOf: url))

        #expect(info.pixelSize == CGSize(width: 320, height: 200))
        #expect(abs(info.duration - 2.5) < 0.01)
    }

    @Test func aTrimmedRecordingSaysHowLongItIsNow() async throws {
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await TestVideos.makeMP4(at: url, frames: [(.blue, 0), (.red, 1)], end: 2)
        try await RecordingFiles.trim(url, to: CMTimeRange(
            start: CMTime(value: 300, timescale: 600),
            end: CMTime(value: 900, timescale: 600)
        ))

        let info = try #require(RecordingFileInfo(contentsOf: url))

        #expect(abs(info.duration - 1) < 0.01)
    }

    @Test func aRecordingCutShortIsNotTakenForOne() async throws {
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await TestVideos.makeMP4(at: url, frames: [(.blue, 0), (.red, 1)], end: 2)
        let data = try Data(contentsOf: url)
        let start = try #require(data.range(of: Data("moov".utf8))).lowerBound - 4
        // Its index missing, as when recording was cut short.
        try (data[..<start] + data[(start + 8)...]).write(to: url)

        #expect(RecordingFileInfo(contentsOf: url) == nil)
        try Data("not a video".utf8).write(to: url)
        #expect(RecordingFileInfo(contentsOf: url) == nil)
    }

    @Test func aFinishedRecordingOfAnInterruptedRunCanBeRestored() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "PashariTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try await writeRecordingAndReleaseRun(root: root, end: 1.5)

        let storage = CaptureStorage(rootDirectory: root)
        var restored: PendingCapture?
        try storage.withInterruptedFiles(includeLegacy: { false }) { files in
            #expect(files.map(\.lastPathComponent) == [file.lastPathComponent])
            restored = try PendingCapture(restoring: try #require(files.first), storage: storage, screenScale: 2)
        }

        let capture = try #require(restored)
        #expect(capture.kind == .recording(duration: 1.5))
        #expect(capture.pointSize == CGSize(width: 32, height: 24))
        #expect(capture.readyFileURL?.lastPathComponent == file.lastPathComponent)
        storage.removeFiles()
    }

    @Test func aRecordingCutShortIsRemovedInsteadOfOffered() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "PashariTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try await writeRecordingAndReleaseRun(root: root, end: 1)
        // What AVFoundation leaves while it writes: an empty file where the
        // recording goes, and the media next to it.
        try Data().write(to: file)
        try Data(repeating: 1, count: 100).write(to: file.deletingLastPathComponent().appending(path: file.lastPathComponent + ".sb-1234"))

        let storage = CaptureStorage(rootDirectory: root)
        try storage.withInterruptedFiles(includeLegacy: { false }) { files in
            #expect(files.isEmpty)
        }

        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    private func writeRecordingAndReleaseRun(root: URL, end: Double) async throws -> URL {
        let run = CaptureStorage(rootDirectory: root)
        let url = try run.makeCaptureDirectory()
            .appending(path: ScreenshotWriter.fileName(capturedAt: Date(), pathExtension: "mp4"))
        try await TestVideos.makeMP4(at: url, frames: [(.blue, 0)], end: end)
        return withExtendedLifetime(run) { url }
    }
}

@MainActor
struct RecordingQuitTests {
    @Test func quittingAsksFirstWhileAPlayerIsOpen() async throws {
        let sample = try await SampleRecording()
        defer { sample.remove() }
        let delegate = AppDelegate(thumbnailController: ThumbnailController(storage: sample.storage))
        var questions = 0
        delegate.confirmQuit = {
            questions += 1
            return false
        }
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow)

        let player = RecordingPlayerWindowController(recording: sample.recording, storage: sample.storage)
        delegate.playerController.keep(player)

        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateCancel)
        #expect(questions == 1)
        player.window.close()
        for _ in 0..<100 where delegate.playerController.hasOpenPlayers {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!delegate.playerController.hasOpenPlayers)
    }
}

/// Quitting while recording, which needs the screen.
@MainActor
@Suite(
    .serialized,
    .enabled(if: CGPreflightScreenCaptureAccess(), "needs the Screen Recording permission"),
    .takesTurnsOnTheScreen
)
struct QuitWhileRecordingTests {
    @Test func aRecordingThatIsRunningEndsAndJoinsTheThumbnailsBeforeTheQuestion() async throws {
        let page = try await ColorPage.show(.pageBlue)
        defer { page.close() }
        _ = try await page.listedContent()
        let storage = try TestStorage()
        defer { storage.remove() }
        let thumbnails = ThumbnailController(storage: storage.storage)
        defer {
            while let card = thumbnails.cards.first { card.onClose?() }
        }
        let displayID = try #require(page.window.screen?.displayID)
        let delegate = AppDelegate(thumbnailController: thumbnails) { thumbnails in
            CaptureCoordinator(
                thumbnailController: thumbnails,
                ensurePermission: { true },
                makeRecordingSession: { storage in
                    AreaRecordingSession(storage: storage, remembered: (displayID, page.area), rememberArea: { _ in })
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

        delegate.captureCoordinator.recordArea()
        try await waitUntil { NSApp.windows.contains { ($0 as? OverlayPanel)?.contentView is RecordingAreaView && $0.isVisible } }
        delegate.captureCoordinator.recordArea()
        try await waitUntil { delegate.captureCoordinator.isRecording }
        try await Task.sleep(for: .milliseconds(300))

        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateLater)
        try await waitUntil { !replies.isEmpty }

        #expect(replies == [false])
        #expect(questions == 1)
        #expect(!delegate.captureCoordinator.isRecording)
        #expect(thumbnails.pendingCount == 1)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
}
