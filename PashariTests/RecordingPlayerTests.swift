import AppKit
import AVFoundation
import AVKit
import Testing

@testable import Pashari

struct TrimHistoryTests {
    private let full = CMTimeRange(start: .zero, duration: CMTime(value: 10, timescale: 1))

    private func range(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
    }

    @Test func aTrimNarrowsWhatPlaysAndUndoWidensItAgain() {
        var history = TrimHistory(full: full)
        #expect(!history.isTrimmed)
        #expect(!history.canUndo)

        history.trim(to: range(1, 8))
        #expect(history.isTrimmed)
        #expect(history.current == range(1, 8))
        #expect(history.canUndo)

        history.undo()
        #expect(!history.isTrimmed)
        #expect(history.canRedo)

        history.redo()
        #expect(history.current == range(1, 8))
    }

    @Test func aTrimThatChangesNothingIsNotKept() {
        var history = TrimHistory(full: full)

        history.trim(to: range(0, 10))

        #expect(!history.canUndo)
        #expect(!history.isTrimmed)
    }

    @Test func aNewTrimAfterUndoLeavesNothingToRedo() {
        var history = TrimHistory(full: full)
        history.trim(to: range(1, 8))
        history.undo()

        history.trim(to: range(2, 5))

        #expect(!history.canRedo)
        history.undo()
        #expect(history.current == full)
    }
}

@MainActor
struct RecordingPlayerTests {
    @Test func cuttingARecordingKeepsOnlyThePartTrimmedTo() async throws {
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let green = TestImages.RGBA(red: 0, green: 200, blue: 0, alpha: 255)
        let gray = TestImages.RGBA(red: 128, green: 128, blue: 128, alpha: 255)
        try await TestVideos.makeMP4(at: url, frames: [(.blue, 0), (.red, 0.5), (green, 1), (gray, 1.5)], end: 2)

        try await RecordingFiles.trim(url, to: CMTimeRange(
            start: CMTime(value: 300, timescale: 600),
            end: CMTime(value: 900, timescale: 600)
        ))

        #expect(abs(try await AVURLAsset(url: url).load(.duration).seconds - 1) < 0.01)
        let first = try await TestVideos.image(in: url, at: 0)
        let later = try await TestVideos.image(in: url, at: 0.7)
        #expect(TestImages.pixel(of: first, x: 32, y: 24).isClose(to: .red, within: 8))
        #expect(TestImages.pixel(of: later, x: 32, y: 24).isClose(to: green, within: 8))
        let left = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(left == [url.lastPathComponent])
    }

    @Test func nothingCutAwayStaysInTheFile() async throws {
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Twenty frames a tenth of a second apart. Only the first is a key
        // frame: they come at least every two seconds.
        let frames = (0..<20).map { index in
            (color: TestImages.RGBA(red: UInt8(index * 12), green: 80, blue: 160, alpha: 255), time: Double(index) / 10)
        }
        try await TestVideos.makeMP4(at: url, frames: frames, end: 2)

        try await RecordingFiles.trim(url, to: CMTimeRange(
            start: CMTime(value: 600, timescale: 600),
            end: CMTime(value: 900, timescale: 600)
        ))

        // Every frame stored in the file, whether players show it or not.
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let cursor = try #require(track.makeSampleCursorAtFirstSampleInDecodeOrder())
        var stored = 1
        while cursor.stepInDecodeOrder(byCount: 1) == 1 {
            stored += 1
        }
        // The five from 1.0 to 1.4 s, and the last one again where it ends.
        #expect(stored <= 6, "\(stored) frames stored")
        let first = TestImages.pixel(of: try await TestVideos.image(in: url, at: 0), x: 32, y: 24)
        #expect(first.isClose(to: frames[10].color, within: 8), "\(first)")
    }

    @Test func undoAndRedoInTheEditMenuReachTheTrims() async throws {
        let sample = try await SampleRecording()
        defer { sample.remove() }
        let player = RecordingPlayerWindowController(
            recording: sample.recording,
            storage: sample.storage,
            showError: { error, _ in Issue.record(error) }
        )
        let undo = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        #expect(!player.window.validateMenuItem(undo))

        player.trim(to: CMTimeRange(start: CMTime(value: 300, timescale: 600), end: CMTime(value: 600, timescale: 600)))
        // The menu's action goes to the window, which tries itself first.
        #expect(player.window.validateMenuItem(undo))
        #expect(player.window.tryToPerform(Selector(("undo:")), with: undo))
        #expect(player.model.canRedo)
        #expect(player.window.validateMenuItem(redo))
        #expect(player.window.tryToPerform(Selector(("redo:")), with: redo))
        #expect(player.model.canUndo)

        // Untrimmed again, closing cuts nothing.
        player.undo(nil)
        player.onClose = nil
        player.window.close()
    }

    @Test func closingAnUntrimmedPlayerHandsTheRecordingBackAsItWas() async throws {
        let sample = try await SampleRecording()
        defer { sample.remove() }
        let player = RecordingPlayerWindowController(
            recording: sample.recording,
            storage: sample.storage,
            showError: { error, _ in Issue.record(error) }
        )
        let results = Results()
        player.onClose = { results.values.append($0) }

        player.window.close()
        try await results.waitForOne()

        let result = try #require(results.values.first ?? nil)
        #expect(result.url == sample.recording.url)
        #expect(result.duration == sample.recording.duration)
        #expect(FileManager.default.fileExists(atPath: result.url.path))
    }

    @Test func closingATrimmedPlayerHandsBackTheRecordingCutToTheTrim() async throws {
        let sample = try await SampleRecording()
        defer { sample.remove() }
        let player = RecordingPlayerWindowController(
            recording: sample.recording,
            storage: sample.storage,
            showError: { error, _ in Issue.record(error) }
        )
        let results = Results()
        player.onClose = { results.values.append($0) }

        player.trim(to: CMTimeRange(start: CMTime(value: 300, timescale: 600), end: CMTime(value: 600, timescale: 600)))
        #expect(player.model.canUndo)
        player.window.close()
        try await results.waitForOne()

        let result = try #require(results.values.first ?? nil)
        #expect(abs(result.duration - 0.5) < 0.01)
        #expect(abs(try await AVURLAsset(url: result.url).load(.duration).seconds - 0.5) < 0.01)
        #expect(TestImages.pixel(of: try await TestVideos.image(in: result.url, at: 0), x: 200, y: 120).isClose(to: .red, within: 8))
    }

    @Test func undoWidensATrimAgainBeforeTheWindowCloses() async throws {
        let sample = try await SampleRecording()
        defer { sample.remove() }
        let player = RecordingPlayerWindowController(
            recording: sample.recording,
            storage: sample.storage,
            showError: { error, _ in Issue.record(error) }
        )
        let results = Results()
        player.onClose = { results.values.append($0) }

        player.trim(to: CMTimeRange(start: CMTime(value: 300, timescale: 600), end: CMTime(value: 600, timescale: 600)))
        player.undo(nil)
        #expect(player.model.canRedo)
        #expect(!player.model.canUndo)
        player.window.close()
        try await results.waitForOne()

        let result = try #require(results.values.first ?? nil)
        #expect(result.duration == sample.recording.duration)
    }

    @Test func copyingFromThePlayerPutsTheFileOnTheClipboardAndClosesIt() async throws {
        let sample = try await SampleRecording()
        defer { sample.remove() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let player = RecordingPlayerWindowController(
            recording: sample.recording,
            storage: sample.storage,
            pasteboard: pasteboard
        )
        let results = Results()
        player.onClose = { results.values.append($0) }

        player.copyRecording(nil)
        try await results.waitForOne()

        #expect(results.values.count == 1)
        #expect(results.values.first! == nil)
        #expect(pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] == [sample.recording.url])
        #expect(FileManager.default.fileExists(atPath: sample.recording.url.path))
    }

    @Test func savingFromThePlayerMovesTheRecordingIntoTheFolder() async throws {
        let sample = try await SampleRecording()
        defer { sample.remove() }
        let destination = sample.root.appending(path: "saved")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let player = RecordingPlayerWindowController(
            recording: sample.recording,
            storage: sample.storage,
            saveDirectory: { destination }
        )
        let results = Results()
        player.onClose = { results.values.append($0) }

        player.saveDocument(nil)
        try await results.waitForOne()

        #expect(results.values.first! == nil)
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: sample.recording.url.lastPathComponent).path))
        #expect(!FileManager.default.fileExists(atPath: sample.recording.url.deletingLastPathComponent().path))
    }

    @Test func savingATrimmedRecordingCutsItStraightIntoTheFolder() async throws {
        let sample = try await SampleRecording()
        defer { sample.remove() }
        let destination = sample.root.appending(path: "saved")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let player = RecordingPlayerWindowController(
            recording: sample.recording,
            storage: sample.storage,
            saveDirectory: { destination },
            showError: { error, _ in Issue.record(error) }
        )
        let results = Results()
        player.onClose = { results.values.append($0) }

        player.trim(to: CMTimeRange(start: CMTime(value: 300, timescale: 600), end: CMTime(value: 600, timescale: 600)))
        player.saveDocument(nil)
        try await results.waitForOne()

        let saved = destination.appending(path: sample.recording.url.lastPathComponent)
        #expect(abs(try await AVURLAsset(url: saved).load(.duration).seconds - 0.5) < 0.01)
        #expect(!FileManager.default.fileExists(atPath: sample.recording.url.deletingLastPathComponent().path))
    }

    @Test func aFailedSaveOfATrimmedRecordingKeepsItAndItsTrims() async throws {
        let sample = try await SampleRecording()
        defer { sample.remove() }
        // A file where the folder should be.
        let notAFolder = sample.root.appending(path: "not-a-folder")
        try Data().write(to: notAFolder)
        var errors = 0
        let player = RecordingPlayerWindowController(
            recording: sample.recording,
            storage: sample.storage,
            saveDirectory: { notAFolder },
            showError: { _, _ in errors += 1 }
        )
        player.onClose = { _ in Issue.record("The player closed") }

        player.trim(to: CMTimeRange(start: CMTime(value: 300, timescale: 600), end: CMTime(value: 600, timescale: 600)))
        player.saveDocument(nil)
        for _ in 0..<200 where errors == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(errors == 1)
        #expect(!player.model.isBusy)
        #expect(player.model.canUndo)
        #expect(player.playerView.player != nil)
        #expect(abs(try await AVURLAsset(url: sample.recording.url).load(.duration).seconds - sample.recording.duration) < 0.01)
        player.onClose = nil
        player.window.close()
    }

    @Test func aSmallRecordingStillLeavesRoomForThePlayersControls() {
        let playerView = AVPlayerView()
        let desk = RecordingDeskView(playerView: playerView, videoSize: CGSize(width: 16, height: 16))
        desk.frame = CGRect(x: 0, y: 0, width: 800, height: 600)

        desk.layout()

        #expect(playerView.frame.width >= RecordingDeskView.minimumPlayerSize.width)
        #expect(playerView.frame.height >= RecordingDeskView.minimumPlayerSize.height)
    }

    @Test func theWindowOpensLargeEnoughForTheVideoAndItsToolbar() {
        let size = RecordingPlayerWindowController.initialContentSize(
            for: CGSize(width: 640, height: 400),
            screenSize: CGSize(width: 1920, height: 1080)
        )
        let margin = (RecordingDeskView.padding + EditorPrintView.border) * 2

        #expect(size == CGSize(width: 640 + margin, height: 400 + margin + EditorToolbarView.height))
    }

    @MainActor
    private final class Results {
        var values: [Recording?] = []

        func waitForOne() async throws {
            for _ in 0..<200 where values.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(values.count == 1)
        }
    }
}
