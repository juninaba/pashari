import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import Pashari

@MainActor
struct ScreenshotWriterTests {
    @Test func fileNameContainsCaptureTime() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = ScreenshotWriter.availableURL(in: directory, capturedAt: sampleDate)

        #expect(url.lastPathComponent == "Pashari 2026-11-10 at 13.08.19.png")
        #expect(url.deletingLastPathComponent().path == directory.path)
    }

    @Test func fileNameGetsCounterWhenTaken() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = ScreenshotWriter.availableURL(in: directory, capturedAt: sampleDate)
        try Data().write(to: first)
        let second = ScreenshotWriter.availableURL(in: directory, capturedAt: sampleDate)
        try Data().write(to: second)
        let third = ScreenshotWriter.availableURL(in: directory, capturedAt: sampleDate)

        #expect(second.lastPathComponent == "Pashari 2026-11-10 at 13.08.19 (2).png")
        #expect(third.lastPathComponent == "Pashari 2026-11-10 at 13.08.19 (3).png")
    }

    @Test func savesPNGAtFullResolutionWithRetinaDensity() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenshot = Screenshot(
            image: try makeImage(width: 200, height: 120),
            scale: 2,
            capturedAt: sampleDate
        )

        let url = try await ScreenshotWriter.save(screenshot, in: directory)

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 200)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 120)
        #expect(properties[kCGImagePropertyDPIWidth] as? Double == 144)
        #expect(properties[kCGImagePropertyDPIHeight] as? Double == 144)
    }

    @Test func savingIntoMissingDirectoryFails() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "pashari-missing-\(UUID().uuidString)")
        let screenshot = Screenshot(
            image: try makeImage(width: 10, height: 10),
            scale: 1,
            capturedAt: sampleDate
        )

        await #expect(throws: CaptureError.self) {
            try await ScreenshotWriter.save(screenshot, in: missing)
        }
    }

    // MARK: - Helpers

    /// 2026-11-10 13:08:19 in the machine's own time zone, which is also what
    /// the file name uses.
    private var sampleDate: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = DateComponents(
            year: 2026, month: 11, day: 10, hour: 13, minute: 8, second: 19
        )
        return calendar.date(from: components)!
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pashari-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
