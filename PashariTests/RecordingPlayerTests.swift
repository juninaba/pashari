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

    @Test func cuttingARecordingWithAudioKeepsOnlyTheTrimmedRangeOfSound() async throws {
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try RecordingWriter(
            url: url,
            width: 64,
            height: 48,
            audioSources: [.system],
            isRealTime: false
        )
        // Video changes colour every 0.5 s over 2 s.
        let green = TestImages.RGBA(red: 0, green: 200, blue: 0, alpha: 255)
        let gray = TestImages.RGBA(red: 128, green: 128, blue: 128, alpha: 255)
        let frames: [(TestImages.RGBA, Double)] = [(.blue, 0), (.red, 0.5), (green, 1.0), (gray, 1.5)]
        var nextFrameIndex = 0
        // Audio has distinct channel activity in each 0.5 s segment:
        // 0.0..0.5: loud Left only (will be cut off at start)
        // 0.5..1.5: loud Right only (kept in trim)
        // 1.5..2.0: loud Left only (will be cut off at end)
        for chunk in 0..<100 {
            let startSec = Double(chunk) * 0.02
            while nextFrameIndex < frames.count, frames[nextFrameIndex].1 <= startSec {
                let (color, time) = frames[nextFrameIndex]
                #expect(try writer.append(TestVideos.frame(width: 64, height: 48, color: color), at: TestVideos.time(time)) == .appended)
                nextFrameIndex += 1
            }
            let audio = try TestVideos.audioBuffer(frames: 960, at: startSec) { index, channel in
                let t = startSec + Double(index) / 48_000
                let tone = Float(sin(2 * .pi * 440 * t)) * 0.5
                if startSec >= 0.5 && startSec < 1.5 {
                    return channel == 1 ? tone : 0
                }
                return channel == 0 ? tone : 0
            }
            try writer.appendAudio(audio, from: .system)
        }
        _ = try await TestVideos.finish(writer, at: 2)

        try await RecordingFiles.trim(url, to: CMTimeRange(
            start: CMTime(value: 300, timescale: 600),
            end: CMTime(value: 900, timescale: 600)
        ))

        let asset = AVURLAsset(url: url)
        #expect(abs(try await asset.load(.duration).seconds - 1) < 0.05)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(audioTracks.count == 1)
        let audioDuration = try await audioTracks[0].load(.timeRange).duration.seconds
        #expect(abs(audioDuration - 1) < 0.06)

        let samples = try await TestVideos.decodedAudioSamples(in: url)
        // Right channel has the kept tone from start to end; Left channel from the cut-off
        // segments (0..0.5 and 1.5..2.0) must not leak into the trimmed file.
        #expect(TestVideos.rms(of: samples, channel: 1, from: 0.05, to: 0.95) > 0.25)
        #expect(TestVideos.rms(of: samples, channel: 0, from: 0.0, to: 0.98) < 0.02)
    }

    @Test func trimmingALongStaticScreenWithContinuousAudioSucceeds() async throws {
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try RecordingWriter(
            url: url,
            width: 64,
            height: 48,
            audioSources: [.system],
            isRealTime: false
        )
        // One static video frame for the entire 20 s recording, with continuous audio.
        #expect(try writer.append(TestVideos.frame(width: 64, height: 48, color: .blue), at: TestVideos.time(0)) == .appended)
        try writer.finishVideo(at: TestVideos.time(20))
        for chunk in 0..<1000 {
            let startSec = Double(chunk) * 0.02
            let audio = try TestVideos.audioBuffer(frames: 960, at: startSec) { index, channel in
                let t = startSec + Double(index) / 48_000
                let tone = Float(sin(2 * .pi * 440 * t)) * 0.4
                if startSec >= 2.345 && startSec < 15.410 {
                    return channel == 1 ? tone : 0
                }
                return channel == 0 ? tone : 0
            }
            try writer.appendAudio(audio, from: .system)
        }
        _ = try await TestVideos.finish(writer, at: 20)

        let range = CMTimeRange(
            start: CMTime(seconds: 2.345, preferredTimescale: 1000),
            end: CMTime(seconds: 15.410, preferredTimescale: 1000)
        )
        try await RecordingFiles.trim(url, to: range)

        let asset = AVURLAsset(url: url)
        #expect(abs(try await asset.load(.duration).seconds - range.duration.seconds) < 0.05)
        let audioTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let audioDuration = try await audioTrack.load(.timeRange).duration.seconds
        #expect(abs(audioDuration - range.duration.seconds) < 0.06)
        let samples = try await TestVideos.decodedAudioSamples(in: url)
        #expect(TestVideos.rms(of: samples, channel: 1, from: 0.1, to: 12.9) > 0.2)
        #expect(TestVideos.rms(of: samples, channel: 0, from: 0.1, to: 12.9) < 0.02)
    }

    @Test func trimmingASilentRecordingLeavesNoAudioTrack() async throws {
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await TestVideos.makeMP4(at: url, frames: [(.blue, 0), (.red, 0.5)], end: 1)

        try await RecordingFiles.trim(url, to: CMTimeRange(
            start: CMTime(value: 150, timescale: 600),
            end: CMTime(value: 450, timescale: 600)
        ))

        let audioTracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        #expect(audioTracks.isEmpty)
    }

    @Test func aCutInTheMiddleOfAStillFrameStartsAndEndsWithIt() async throws {
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // The screen stood still for five seconds.
        try await TestVideos.makeMP4(at: url, frames: [(.blue, 0), (.red, 5)], end: 6)

        try await RecordingFiles.trim(url, to: CMTimeRange(
            start: CMTime(value: 2, timescale: 1),
            end: CMTime(value: 3, timescale: 1)
        ))

        #expect(abs(try await AVURLAsset(url: url).load(.duration).seconds - 1) < 0.01)
        for time in [0, 0.95] {
            let pixel = TestImages.pixel(of: try await TestVideos.image(in: url, at: time), x: 32, y: 24)
            #expect(pixel.isClose(to: .blue, within: 8), "\(time) s: \(pixel)")
        }
    }

    @Test func aTrimmedSaveNeverTouchesAFileInTheFolder() async throws {
        let sample = try await SampleRecording()
        defer { sample.remove() }
        let folder = sample.root.appending(path: "saved")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A file of the same name is already there.
        let existing = folder.appending(path: sample.recording.url.lastPathComponent)
        try Data("someone else's".utf8).write(to: existing)

        // A cut that comes out empty, past the end, fails.
        await #expect(throws: CaptureError.self) {
            try await RecordingFiles.trim(sample.recording.url, to: CMTimeRange(
                start: CMTime(value: 5, timescale: 1),
                end: CMTime(value: 6, timescale: 1)
            ), into: folder)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [existing.lastPathComponent])
        #expect(try FileManager.default.contentsOfDirectory(atPath: sample.recording.url.deletingLastPathComponent().path)
            == [sample.recording.url.lastPathComponent])

        try await RecordingFiles.trim(sample.recording.url, to: CMTimeRange(
            start: CMTime(value: 300, timescale: 600),
            end: CMTime(value: 600, timescale: 600)
        ), into: folder)

        #expect(try Data(contentsOf: existing) == Data("someone else's".utf8))
        let saved = folder.appending(path: existing.deletingPathExtension().lastPathComponent + "-2.mp4")
        #expect(abs(try await AVURLAsset(url: saved).load(.duration).seconds - 0.5) < 0.01)
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
