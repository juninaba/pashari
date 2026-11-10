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

    @Test func aspectFitCentresThePicture() {
        let fitted = ThumbnailPreviewView.aspectFit(
            CGSize(width: 400, height: 100),
            in: CGRect(x: 0, y: 0, width: 200, height: 200)
        )

        #expect(fitted == CGRect(x: 0, y: 75, width: 200, height: 50))
    }
}

@MainActor
struct PendingCaptureTests {
    @Test func preparesAPNGFileNamedAfterTheCaptureTime() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pashari-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenshot = Screenshot(
            image: TestImages.make(width: 60, height: 40),
            scale: 2,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let capture = PendingCapture(screenshot: screenshot, temporaryDirectory: directory)
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

        let first = try await PendingCapture(screenshot: screenshot, temporaryDirectory: directory).file()
        let second = try await PendingCapture(screenshot: screenshot, temporaryDirectory: directory).file()

        #expect(first.url != second.url)
        #expect(first.url.lastPathComponent == second.url.lastPathComponent)
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
