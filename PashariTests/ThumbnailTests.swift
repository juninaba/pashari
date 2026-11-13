import AppKit
import Testing

@testable import Pashari

@MainActor
struct ThumbnailLayoutTests {
    @Test func largeScreenshotIsScaledDownKeepingItsProportions() {
        // A 16:10 full screen.
        let size = ThumbnailLayout.previewSize(for: CGSize(width: 1728, height: 1080))

        #expect(size == CGSize(width: 240, height: 150))
    }

    @Test func tallScreenshotIsLimitedByHeight() {
        let size = ThumbnailLayout.previewSize(for: CGSize(width: 400, height: 800))

        #expect(size.height == 160)
        // 80 wide by proportion, widened to the minimum so the buttons fit.
        #expect(size.width == ThumbnailLayout.minimumPreviewSize.width)
    }

    @Test func smallScreenshotIsNotScaledUp() {
        let size = ThumbnailLayout.previewSize(for: CGSize(width: 200, height: 100))

        #expect(size == CGSize(width: 200, height: 100))
    }

    @Test func tinyScreenshotGetsTheMinimumSize() {
        let size = ThumbnailLayout.previewSize(for: CGSize(width: 10, height: 10))

        #expect(size == ThumbnailLayout.minimumPreviewSize)
    }

    @Test func cardAddsTheToolbarUnderThePreview() {
        let card = ThumbnailLayout.cardSize(for: CGSize(width: 1728, height: 1080))

        #expect(card == CGSize(width: 240, height: 150 + ThumbnailLayout.toolbarHeight))
    }

    @Test func cardsStackUpwardsFromTheBottomLeftCorner() {
        let area = CGRect(x: 100, y: 50, width: 1000, height: 700)
        let sizes = [CGSize(width: 240, height: 184), CGSize(width: 200, height: 134)]

        let frames = ThumbnailLayout.stackFrames(for: sizes, in: area)

        #expect(frames == [
            CGRect(x: 116, y: 66, width: 240, height: 184),
            CGRect(x: 116, y: 66 + 184 + 10, width: 200, height: 134),
        ])
    }

    @Test func onlyTheCardsThatFitTheScreenHeightStay() {
        // Five 16:10 captures: cards 184 points tall, 10 apart, and 16 from
        // the edges of the screen.
        let sizes = Array(repeating: CGSize(width: 240, height: 184), count: 5)

        // 16 + 3 × 184 + 2 × 10 = 588 fits below 700 - 16; a fourth card
        // would reach 782.
        let small = CGRect(x: 0, y: 0, width: 1000, height: 700)
        #expect(ThumbnailLayout.fittingCount(for: sizes, in: small) == 3)
        // 16 + 5 × 184 + 4 × 10 = 976 fits below 1000 - 16.
        let large = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        #expect(ThumbnailLayout.fittingCount(for: sizes, in: large) == 5)
    }

    @Test func theNewestCardStaysEvenWhenNothingFits() {
        let sizes = [CGSize(width: 240, height: 184)]
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 100)

        #expect(ThumbnailLayout.fittingCount(for: sizes, in: tiny) == 1)
    }

    @Test func aspectFitCentresThePicture() {
        let fitted = ThumbnailPreviewView.aspectFit(
            CGSize(width: 400, height: 100),
            in: CGRect(x: 0, y: 0, width: 200, height: 200)
        )

        #expect(fitted == CGRect(x: 0, y: 75, width: 200, height: 50))
    }
}

@MainActor
struct ThumbnailControllerTests {
    @Test func closingImmediatelyAfterSaveWaitsForTheCaptureToBeDelivered() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "saved")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var errors = 0
        let controller = ThumbnailController(
            storageDirectory: root.appending(path: "working"),
            saveDirectory: { destination },
            showError: { _, _ in errors += 1 }
        )
        let screenshot = makeScreenshot()
        controller.show(screenshot)
        let panel = try #require(controller.panels.first)
        let card = try #require(panel.contentView as? ThumbnailCardView)
        defer { card.onClose?() }
        let buttons = card.subviews.flatMap(\.subviews).compactMap { $0 as? NSButton }
        try #require(buttons.count == 4)

        // Both actions run before the preparation or delivery task can finish.
        card.onSave?()
        card.onClose?()
        #expect(controller.pendingCount == 1)
        #expect(buttons.allSatisfy { !$0.isEnabled })
        #expect(card.previewView.fileURL?() == nil)

        for _ in 0..<200 where controller.hasPendingCaptures && errors == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(errors == 0)
        #expect(!controller.hasPendingCaptures)
        let saved = destination.appending(path: ScreenshotWriter.fileName(capturedAt: screenshot.capturedAt))
        let expected = try await ScreenshotWriter.pngData(for: screenshot)
        #expect(try Data(contentsOf: saved) == expected)
    }

    @Test func aFailedSaveReenablesActionsAndKeepsTheCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "not-a-directory")
        try Data().write(to: destination)
        var errors = 0
        let controller = ThumbnailController(
            storageDirectory: root.appending(path: "working"),
            saveDirectory: { destination },
            showError: { _, _ in errors += 1 }
        )
        controller.show(makeScreenshot())
        let panel = try #require(controller.panels.first)
        let card = try #require(panel.contentView as? ThumbnailCardView)
        defer { card.onClose?() }
        card.onSave?()
        card.onClose?()

        for _ in 0..<200 where errors == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(errors == 1)
        #expect(controller.pendingCount == 1)
        let buttons = card.subviews.flatMap(\.subviews).compactMap { $0 as? NSButton }
        #expect(buttons.allSatisfy { $0.isEnabled })
        let file = try #require(card.previewView.fileURL?())
        #expect(FileManager.default.fileExists(atPath: file.path))
        card.onClose?()
        #expect(!controller.hasPendingCaptures)
    }

    @Test func overflowCapturesKeepTheirFilesAndReturnWhenThereIsRoom() async throws {
        let controller = ThumbnailController()
        defer {
            while let panel = controller.panels.first { close(panel) }
        }
        #expect(!controller.hasPendingCaptures)

        controller.show(makeScreenshot())
        weak var oldPanel: NSPanel?
        let file: URL
        do {
            let panel = try #require(controller.panels.first)
            oldPanel = panel
            let card = try #require(panel.contentView as? ThumbnailCardView)
            for _ in 0..<100 where card.previewView.fileURL?() == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            file = try #require(card.previewView.fileURL?())
        }

        for _ in 0...ThumbnailLayout.maximumCount {
            controller.show(makeScreenshot())
        }
        #expect(controller.pendingCount == ThumbnailLayout.maximumCount + 2)
        #expect(controller.panels.count <= ThumbnailLayout.maximumCount)
        #expect(controller.hasPendingCaptures)

        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: NSApp
        )
        // AppKit may retain the window object briefly, but its views and
        // backing store must be discarded when it leaves the visible stack.
        if let oldPanel {
            #expect(oldPanel.contentView == nil)
            #expect(!oldPanel.isVisible)
        }
        #expect(controller.pendingCount == ThumbnailLayout.maximumCount + 2)
        #expect(FileManager.default.fileExists(atPath: file.path))

        while controller.pendingCount > 1 {
            close(try #require(controller.panels.first))
        }
        let restored = try #require(controller.panels.first)
        let restoredCard = try #require(restored.contentView as? ThumbnailCardView)
        #expect(restored.isVisible)
        #expect(controller.panels.count == 1)
        #expect(restoredCard.previewView.fileURL?() == file)
        for _ in 0..<100 where restoredCard.previewView.layer?.contents == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(restoredCard.previewView.layer?.contents != nil)
        #expect(FileManager.default.fileExists(atPath: file.path))

        var annotated: Screenshot?
        controller.onAnnotate = { annotated = $0 }
        restoredCard.onAnnotate?()
        for _ in 0..<100 where annotated == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let screenshot = try #require(annotated)
        #expect(screenshot.image.width == 200)
        #expect(screenshot.image.height == 120)
        #expect(screenshot.scale == 2)
        #expect(TestImages.pixel(of: screenshot.image, x: 20, y: 20) == .blue)
        #expect(!controller.hasPendingCaptures)
    }

    @Test func aThumbnailForADisplayThatIsGoneMovesToTheScreenInUse() throws {
        let controller = ThumbnailController()
        // No screen has this ID, as if its display had just been unplugged.
        controller.show(makeScreenshot(), onDisplay: 0xDEAD_BEEF)
        let panel = try #require(controller.panels.first)
        defer { close(panel) }

        let screen = try #require(NSScreen.underMouse ?? NSScreen.main)
        let expected = ThumbnailLayout.stackFrames(for: [panel.frame.size], in: screen.visibleFrame)
        #expect(panel.frame == expected.first)
    }

    @Test func thumbnailsAreLaidOutAgainWhenDisplaysChange() async throws {
        let controller = ThumbnailController()
        controller.show(makeScreenshot())
        let panel = try #require(controller.panels.first)
        defer { close(panel) }
        let home = panel.frame
        // Far from any screen, where a layout for a display that is gone
        // would leave it.
        panel.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))

        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: NSApp
        )
        for _ in 0..<100 where panel.frame != home {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(panel.frame == home)
    }

    /// Closes the thumbnail the way its close button does, which also deletes
    /// its temporary file.
    private func close(_ panel: NSPanel) {
        (panel.contentView as? ThumbnailCardView)?.onClose?()
    }
}

@MainActor
struct PendingCaptureTests {
    @Test func restoresTheFullImageAndMetadataFromItsPNG() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Screenshot(
            image: TestImages.make(width: 60, height: 40, patchRect: CGRect(x: 0, y: 0, width: 10, height: 10)),
            scale: 2, capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let capture = PendingCapture(screenshot: original, directory: directory)
        _ = try await capture.fileURL()

        let restored = try await capture.screenshot()
        #expect(restored.image !== original.image)
        #expect(restored.pointSize == original.pointSize)
        #expect(restored.scale == original.scale)
        #expect(restored.capturedAt == original.capturedAt)
        #expect(TestImages.pixel(of: restored.image, x: 5, y: 5) == .red)
        #expect(TestImages.pixel(of: restored.image, x: 20, y: 20) == .blue)
        let thumbnail = try await capture.thumbnail(maxPixelSize: 20)
        #expect(thumbnail.width == 20)
        #expect(thumbnail.height <= 20)
    }

    @Test func releasesTheOriginalPixelsAfterWritingEvenWhileAPreviewIsHeld() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let released = DispatchSemaphore(value: 0)
        let capture = PendingCapture(
            screenshot: Screenshot(image: TestImages.tracked(released: released), scale: 2, capturedAt: Date()),
            directory: directory
        )
        let thumbnail = try await capture.thumbnail(maxPixelSize: 20)
        _ = try await capture.fileURL()

        func sourceWasReleased() -> Bool {
            released.wait(timeout: .now()) == .success
        }
        var pixelsReleased = false
        for _ in 0..<100 {
            if sourceWasReleased() {
                pixelsReleased = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(pixelsReleased)
        #expect(thumbnail.width == 20)
        #expect(try await capture.screenshot().image.width == 60)
    }

    @Test func keepsTheOriginalWhenWritingTheTemporaryFileFails() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data().write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let original = makeScreenshot()
        let capture = PendingCapture(screenshot: original, directory: path)
        await #expect(throws: (any Error).self) { try await capture.fileURL() }

        #expect(capture.readyFileURL == nil)
        let restored = try await capture.screenshot()
        #expect(restored.image === original.image)
        #expect(try await capture.thumbnail(maxPixelSize: 20).width == 20)
    }

    @Test func preparesAPNGFileNamedAfterTheCaptureTime() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pashari-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenshot = Screenshot(
            image: TestImages.make(width: 60, height: 40),
            scale: 2,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let capture = PendingCapture(screenshot: screenshot, directory: directory)
        let file = try await capture.file()

        #expect(file.url.path.hasPrefix(directory.path))
        #expect(file.url.lastPathComponent == ScreenshotWriter.fileName(capturedAt: screenshot.capturedAt))
        #expect(try Data(contentsOf: file.url) == file.data)
        // Every PNG file starts with these eight bytes.
        #expect(file.data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    @Test func twoCapturesFromTheSameSecondDoNotCollide() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pashari-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenshot = Screenshot(
            image: TestImages.make(width: 10, height: 10),
            scale: 1,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let first = try await PendingCapture(screenshot: screenshot, directory: directory).file()
        let second = try await PendingCapture(screenshot: screenshot, directory: directory).file()

        #expect(first.url != second.url)
        #expect(first.url.lastPathComponent == second.url.lastPathComponent)
    }

    @Test func removingTheFileDeletesItsFolder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pashari-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenshot = Screenshot(
            image: TestImages.make(width: 10, height: 10),
            scale: 1,
            capturedAt: Date()
        )
        let capture = PendingCapture(screenshot: screenshot, directory: directory)
        let file = try await capture.file()

        await capture.removeFile()

        #expect(!FileManager.default.fileExists(atPath: file.url.deletingLastPathComponent().path))
    }

    @Test func aFileRemovedBeforeItIsWrittenDoesNotAppearLater() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pashari-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenshot = Screenshot(
            image: TestImages.make(width: 10, height: 10),
            scale: 1,
            capturedAt: Date()
        )

        // Closed straight away, while the PNG may still be encoding.
        await PendingCapture(screenshot: screenshot, directory: directory).removeFile()

        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}

@MainActor
struct ClipboardTests {
    @Test func copyReplacesThePasteboardContentsWithThePNG() {
        // A private pasteboard, so the test leaves the real clipboard alone.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pashari-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("old text", forType: .string)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

        Clipboard.copy(pngData: png, to: pasteboard)

        #expect(pasteboard.data(forType: .png) == png)
        #expect(pasteboard.string(forType: .string) == nil)
    }
}
