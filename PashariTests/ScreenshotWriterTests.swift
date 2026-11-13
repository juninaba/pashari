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

        #expect(url.lastPathComponent == "pashari-20261110-ktwu.png")
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

        #expect(second.lastPathComponent == "pashari-20261110-ktwu-2.png")
        #expect(third.lastPathComponent == "pashari-20261110-ktwu-3.png")
    }

    @Test func timeCodeCountsQuarterSecondsSinceMidnight() {
        let calendar = utcCalendar
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10))!
        func code(_ seconds: TimeInterval) -> String {
            ScreenshotWriter.timeCode(for: midnight + seconds, in: calendar)
        }

        #expect(code(0) == "aaaa")
        #expect(code(0.2) == "aaaa")
        #expect(code(0.25) == "aaab")
        #expect(code(6.5) == "aaba")
        #expect(code(13 * 3600 + 8 * 60 + 19) == "ktwu")
        #expect(code(86_399.75) == "trgh")
    }

    @Test func fileNamesSortInTheOrderTheyWereTaken() {
        let start = sampleDate
        let names = stride(from: 0, to: 2 * 86_400, by: 97.25).map {
            ScreenshotWriter.fileName(capturedAt: start + $0)
        }

        #expect(names == names.sorted())
        #expect(Set(names).count == names.count)
    }

    @Test func timeCodeKeepsRisingWhenTheClocksGoBack() throws {
        var london = Calendar(identifier: .gregorian)
        london.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        // On 25 October 2026 the UK clocks go back from 2:00 to 1:00, so they
        // show 1:30 twice: at 0:30 UTC and again at 1:30 UTC.
        let first = utcCalendar.date(
            from: DateComponents(year: 2026, month: 10, day: 25, hour: 0, minute: 30)
        )!
        let second = utcCalendar.date(
            from: DateComponents(year: 2026, month: 10, day: 25, hour: 1, minute: 30)
        )!
        #expect(
            london.dateComponents([.hour, .minute], from: first)
                == london.dateComponents([.hour, .minute], from: second)
        )

        #expect(
            ScreenshotWriter.timeCode(for: first, in: london)
                < ScreenshotWriter.timeCode(for: second, in: london)
        )
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

    private var sampleDate: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = DateComponents(
            year: 2026, month: 11, day: 10, hour: 13, minute: 8, second: 19
        )
        return calendar.date(from: components)!
    }

    /// A calendar in UTC, so the expected codes are the same on any machine.
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
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
