import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns screenshots into PNG data and PNG files.
enum ScreenshotWriter {
    /// Encodes the screenshot and saves it into `directory`. Returns the
    /// file's URL.
    static func save(_ screenshot: Screenshot, in directory: URL) async throws -> URL {
        let data = try await pngData(for: screenshot)
        return try write(data, in: directory, capturedAt: screenshot.capturedAt)
    }

    /// Writes already-encoded PNG data into `directory` under a name that is
    /// not taken yet. Returns the file's URL.
    static func write(_ data: Data, in directory: URL, capturedAt date: Date) throws -> URL {
        let url = availableURL(in: directory, capturedAt: date)
        do {
            try data.write(to: url)
        } catch {
            throw CaptureError.cannotWriteFile(url)
        }
        return url
    }

    /// "pashari-20261110-ktwu.png"
    static func fileName(capturedAt date: Date) -> String {
        "\(baseName(capturedAt: date)).png"
    }

    /// The file name for `date` inside `directory`, with "-2", "-3"...
    /// appended when a file of that name already exists.
    static func availableURL(in directory: URL, capturedAt date: Date) -> URL {
        let baseName = baseName(capturedAt: date)
        var url = directory.appending(path: "\(baseName).png")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appending(path: "\(baseName)-\(counter).png")
            counter += 1
        }
        return url
    }

    /// "pashari-20261110-ktwu": the day of the capture, then the time of day
    /// as four letters.
    private static func baseName(capturedAt date: Date) -> String {
        // Gregorian, so the year is 2026 even on a Mac set to another
        // calendar, and in the Mac's time zone, so the date matches its clock.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let formatter = DateFormatter()
        // A fixed locale keeps plain digits whatever the region settings are.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyyMMdd"
        return "pashari-\(formatter.string(from: date))-\(timeCode(for: date, in: calendar))"
    }

    /// The time of day as four letters, in quarter seconds: "aaaa" at
    /// midnight, "aaab" a quarter second later, up to "trgh" at 23:59:59.75.
    ///
    /// It is the number of quarter seconds since midnight, written in base 26
    /// with the letters a to z as digits, the way hexadecimal uses 0 to f.
    /// A day has 345,600 quarter seconds and four letters make 26⁴ = 456,976
    /// codes, so four are enough. Every code has the same length, so sorting
    /// files by name also sorts them by time.
    ///
    /// It counts the time that has passed since midnight rather than reading
    /// the clock. On the night the clocks go back, the clock shows the same
    /// hour twice, and a code read off it would go backwards.
    static func timeCode(for date: Date, in calendar: Calendar) -> String {
        let seconds = date.timeIntervalSince(calendar.startOfDay(for: date))
        // Kept within what four letters can hold.
        var count = min(max(Int(seconds * 4), 0), 26 * 26 * 26 * 26 - 1)

        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var code = ""
        for _ in 0..<4 {
            // Takes the last digit each time, so each letter goes in front.
            code.insert(letters[count % 26], at: code.startIndex)
            count /= 26
        }
        return code
    }

    /// Encodes the screenshot as PNG.
    ///
    /// `@concurrent` moves the work off the main thread: compressing a full
    /// Retina screen takes long enough to make the UI stutter otherwise.
    @concurrent
    static func pngData(for screenshot: Screenshot) async throws -> Data {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw CaptureError.cannotEncodeImage
        }

        // Record the pixel density (144 dpi for Retina). Apps such as Preview
        // use it to show the image at the size it had on screen, not doubled.
        let dpi = 72 * screenshot.scale
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(destination, screenshot.image, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.cannotEncodeImage
        }
        return data as Data
    }
}
