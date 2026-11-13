import Foundation
import ImageIO

/// A screenshot that has been taken but not yet copied, saved or discarded.
/// This is what a floating thumbnail stands for.
///
/// As soon as it is created it starts encoding the PNG in the background and
/// writes it to a working file. Once that succeeds, only metadata stays in
/// memory. Copy, Save and the editor read the file when they need it.
final class PendingCapture {
    /// The encoded image and the working file holding it.
    struct File: Sendable {
        let data: Data
        let url: URL
    }

    let pointSize: CGSize
    let capturedAt: Date
    private let scale: CGFloat
    private let url: URL
    private var original: Screenshot?

    /// Returns no image or PNG data, so a completed task retains no large buffers.
    private let preparation: Task<Void, Error>

    /// The file, once it is ready. Drag and drop needs the answer right away
    /// and cannot wait, so it reads this instead of awaiting `fileURL()`.
    private(set) var readyFileURL: URL?

    init(screenshot: Screenshot, directory: URL = CaptureStorage.current.directory) {
        pointSize = screenshot.pointSize
        capturedAt = screenshot.capturedAt
        scale = screenshot.scale
        original = screenshot
        // Each capture gets a folder of its own, so the file inside can
        // carry the plain name it will have wherever it is dropped.
        let url = directory
            .appending(path: UUID().uuidString)
            .appending(path: ScreenshotWriter.fileName(capturedAt: screenshot.capturedAt))
        self.url = url
        preparation = Task {
            let data = try await ScreenshotWriter.pngData(for: screenshot)
            try await Self.write(data, to: url)
        }
        Task {
            _ = try? await fileURL()
        }
    }

    /// The encoded image and its working file, waiting for them if needed.
    func file() async throws -> File {
        let url = try await fileURL()
        return File(data: try await Self.readData(from: url), url: url)
    }

    /// Keeps the original if writing fails: it may be the only copy left.
    func fileURL() async throws -> URL {
        try await preparation.value
        original = nil
        readyFileURL = url
        return url
    }

    func screenshot() async throws -> Screenshot {
        if let original { return original }
        let image = try await Self.readImage(from: url)
        return Screenshot(image: image, scale: scale, capturedAt: capturedAt)
    }

    /// A standalone small bitmap, so a preview never retains a full frame.
    func thumbnail(maxPixelSize: Int) async throws -> CGImage {
        if let original {
            return try await Self.resize(original.image, maxPixelSize: maxPixelSize)
        }
        return try await Self.readImage(from: url, maxPixelSize: maxPixelSize)
    }

    @concurrent
    private static func readData(from url: URL) async throws -> Data {
        try Data(contentsOf: url)
    }

    @concurrent
    private static func readImage(from url: URL, maxPixelSize: Int? = nil) async throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw CaptureError.cannotReadFile(url)
        }
        let image: CGImage?
        if let maxPixelSize {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        }
        guard let image else { throw CaptureError.cannotReadFile(url) }
        return image
    }

    @concurrent
    private static func resize(_ image: CGImage, maxPixelSize: Int) async throws -> CGImage {
        let factor = min(CGFloat(maxPixelSize) / CGFloat(max(image.width, image.height)), 1)
        let width = max(Int((CGFloat(image.width) * factor).rounded()), 1)
        let height = max(Int((CGFloat(image.height) * factor).rounded()), 1)
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CaptureError.cannotEncodeImage
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumbnail = context.makeImage() else { throw CaptureError.cannotEncodeImage }
        return thumbnail
    }

    // MARK: - Working files

    /// Deletes the working file after delivery or discard. If the file is
    /// still being written, this waits for that first; otherwise the file
    /// would appear after it was meant to be deleted.
    func removeFile() async {
        guard let url = try? await fileURL() else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// A full Retina screenshot is several megabytes. `@concurrent` writes
    /// it off the main thread, so the screen does not stutter meanwhile.
    @concurrent
    private static func write(_ data: Data, to url: URL) async throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }
}
