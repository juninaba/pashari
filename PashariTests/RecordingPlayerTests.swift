import AppKit
import AVFoundation
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

    @Test func closingAnUntrimmedPlayerHandsTheRecordingBackAsItWas() async throws {
        let sample = try await SampleRecording()
        defer { sample.remove() }
        let player = RecordingPlayerWindowController(recording: sample.recording, storage: sample.storage)
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
        let player = RecordingPlayerWindowController(recording: sample.recording, storage: sample.storage)
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
        let player = RecordingPlayerWindowController(recording: sample.recording, storage: sample.storage)
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
