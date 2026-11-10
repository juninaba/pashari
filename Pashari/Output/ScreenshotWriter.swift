import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns screenshots into PNG data and PNG files.
enum ScreenshotWriter {
    /// The folder screenshots go to until there is a setting for it.
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

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

    /// "Pashari 2026-11-10 at 13.08.19.png"
    static func fileName(capturedAt date: Date) -> String {
        "\(baseName(capturedAt: date)).png"
    }

    /// The file name for `date` inside `directory`, with " (2)", " (3)"...
    /// appended when a file of that name already exists.
    static func availableURL(in directory: URL, capturedAt date: Date) -> URL {
        let baseName = baseName(capturedAt: date)
        var url = directory.appending(path: "\(baseName).png")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appending(path: "\(baseName) (\(counter)).png")
            counter += 1
        }
        return url
    }

    private static func baseName(capturedAt date: Date) -> String {
        let formatter = DateFormatter()
        // A fixed locale keeps the format identical regardless of the user's
        // region and calendar settings.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Pashari \(formatter.string(from: date))"
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
