import AppKit
import Testing

@testable import Pashari

@MainActor
struct RecordingThumbnailTests {
    @Test func aRecordingsCardHasPlayInsteadOfAnnotateAndShowsItsLength() throws {
        let card = ThumbnailCardView(imageSize: CGSize(width: 400, height: 300), duration: 12.4)

        let buttons = card.subviews.flatMap(\.subviews).compactMap { $0 as? ThumbnailButton }
        #expect(buttons.map { $0.accessibilityLabel() } == [
            String(localized: "Copy"), String(localized: "Save"), String(localized: "Play"), String(localized: "Close"),
        ])
        #expect(card.duration == 12.4)
        #expect(ThumbnailCardView.durationText(12.4) == "0:12")
        #expect(ThumbnailCardView.durationText(0.3) == "0:01")
        #expect(ThumbnailCardView.durationText(299.6) == "5:00")
    }

    @Test func aRecordingsThumbnailIsItsFirstFrame() async throws {
        let sample = try await SampleRecording()
        defer { sample.remove() }

        let capture = PendingCapture(recording: sample.recording)
        let image = try await capture.thumbnail(maxPixelSize: 100)

        #expect(max(image.width, image.height) == 100)
        #expect(TestImages.pixel(of: image, x: 50, y: 30).isClose(to: .blue, within: 8))
        #expect(capture.readyFileURL == sample.recording.url)
    }

    @Test func copyingARecordingPutsItsFileOnTheClipboardAndKeepsItUntilQuit() async throws {
        let sample = try await SampleRecording()
        defer { sample.remove() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let controller = ThumbnailController(storage: sample.storage, showError: { error, _ in
            Issue.record(error)
        }, pasteboard: pasteboard)
        controller.show(sample.recording)
        let card = try #require(controller.cards.first)

        card.onCopy?()
        for _ in 0..<100 where controller.hasPendingCaptures {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!controller.hasPendingCaptures)
        let copied = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        #expect(copied == [sample.recording.url])
        #expect(FileManager.default.fileExists(atPath: sample.recording.url.path))
        // A normal quit deletes it.
        sample.storage.removeFiles()
        #expect(!FileManager.default.fileExists(atPath: sample.recording.url.path))
    }

    @Test func savingARecordingMovesItIntoTheChosenFolder() async throws {
        let sample = try await SampleRecording()
        defer { sample.remove() }
        let destination = sample.root.appending(path: "saved")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let controller = ThumbnailController(
            storage: sample.storage,
            saveDirectory: { destination },
            showError: { error, _ in Issue.record(error) }
        )
        controller.show(sample.recording)
        let card = try #require(controller.cards.first)

        card.onSave?()
        for _ in 0..<100 where controller.hasPendingCaptures {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!controller.hasPendingCaptures)
        let saved = destination.appending(path: sample.recording.url.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: saved.path))
        #expect(!FileManager.default.fileExists(atPath: sample.recording.url.deletingLastPathComponent().path))
    }

    @Test func playingARecordingHandsItsFileToThePlayer() async throws {
        let sample = try await SampleRecording()
        defer { sample.remove() }
        let controller = ThumbnailController(storage: sample.storage)
        var played: Recording?
        controller.onPlay = { played = $0 }
        controller.show(sample.recording)
        let card = try #require(controller.cards.first)

        card.onPlay?()

        #expect(played?.url == sample.recording.url)
        #expect(played?.duration == sample.recording.duration)
        #expect(!controller.hasPendingCaptures)
        try await Task.sleep(for: .milliseconds(50))
        #expect(FileManager.default.fileExists(atPath: sample.recording.url.path))
    }

    @Test func doubleClickingARecordingsPicturePlaysIt() async throws {
        let sample = try await SampleRecording()
        defer { sample.remove() }
        let controller = ThumbnailController(storage: sample.storage, showError: { error, _ in
            Issue.record(error)
        })
        // Before its file goes, should the card still be there.
        defer { controller.cards.first?.onClose?() }
        var played: Recording?
        controller.onPlay = { played = $0 }
        controller.onAnnotate = { _ in Issue.record("A recording went to the editor") }
        controller.show(sample.recording)
        let card = try #require(controller.cards.first)
        let panel = try #require(card.window)
        card.paper.removeAllAnimations()
        CATransaction.flush()
        let picture = card.previewView.convert(card.previewView.bounds, to: nil)
        let point = CGPoint(x: picture.midX, y: picture.midY)

        try sendClick(at: point, to: panel, count: 1)
        #expect(played == nil)
        try sendClick(at: point, to: panel, count: 2)

        #expect(played?.url == sample.recording.url)
        #expect(!controller.hasPendingCaptures)
    }

    @Test func closingARecordingsCardDeletesItsFile() async throws {
        let sample = try await SampleRecording()
        defer { sample.remove() }
        let controller = ThumbnailController(storage: sample.storage)
        controller.show(sample.recording)
        let card = try #require(controller.cards.first)

        card.onClose?()
        for _ in 0..<100 where FileManager.default.fileExists(atPath: sample.recording.url.path) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!FileManager.default.fileExists(atPath: sample.recording.url.path))
    }

    @Test func aFileOnTheClipboardIsTheFileItself() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let url = URL(fileURLWithPath: "/tmp/pashari-20261120-aaaa.mp4")

        Clipboard.copy(fileURL: url, to: pasteboard)

        #expect(pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] == [url])
    }
}

/// A one-second recording, first blue then red, in its own working folder.
@MainActor
struct SampleRecording {
    let root: URL
    let storage: CaptureStorage
    let recording: Recording

    init(pointSize: CGSize = CGSize(width: 200, height: 120)) async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "PashariTests-\(UUID().uuidString)")
        storage = CaptureStorage(rootDirectory: root.appending(path: "working"))
        let capturedAt = Date()
        let url = try storage.makeCaptureDirectory()
            .appending(path: ScreenshotWriter.fileName(capturedAt: capturedAt, pathExtension: "mp4"))
        let duration = try #require(try await TestVideos.makeMP4(
            at: url,
            width: Int(pointSize.width) * 2,
            height: Int(pointSize.height) * 2,
            frames: [(.blue, 0), (.red, 0.5)],
            end: 1
        ))
        recording = Recording(url: url, pointSize: pointSize, duration: duration, capturedAt: capturedAt)
    }

    func remove() {
        storage.removeFiles()
        try? FileManager.default.removeItem(at: root)
    }
}
