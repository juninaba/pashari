import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes screenshots to disk as PNG files.
enum ScreenshotWriter {
    /// Saves the screenshot into `directory` and returns the file's URL.
    static func save(_ screenshot: Screenshot, in directory: URL) async throws -> URL {
        let url = availableURL(in: directory, capturedAt: screenshot.capturedAt)
        try await writePNG(screenshot.image, scale: screenshot.scale, to: url)
        return url
    }

    /// The folder screenshots go to until there is a setting for it.
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    /// "Pashari 2026-11-10 at 13.08.19.png", with " (2)", " (3)"... appended
    /// when a file of that name already exists.
    static func availableURL(in directory: URL, capturedAt date: Date) -> URL {
        let formatter = DateFormatter()
        // A fixed locale keeps the format identical regardless of the user's
        // region and calendar settings.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let baseName = "Pashari \(formatter.string(from: date))"

        var url = directory.appending(path: "\(baseName).png")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appending(path: "\(baseName) (\(counter)).png")
            counter += 1
        }
        return url
    }

    /// Encodes and writes the PNG off the main thread. Compressing a full
    /// Retina screen takes long enough to make the UI stutter otherwise.
    @concurrent
    private static func writePNG(_ image: CGImage, scale: CGFloat, to url: URL) async throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw CaptureError.cannotWriteFile(url)
        }

        // Record the pixel density (144 dpi for Retina). Apps such as Preview
        // use it to show the image at the size it had on screen, not doubled.
        let dpi = 72 * scale
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.cannotWriteFile(url)
        }
    }
}
