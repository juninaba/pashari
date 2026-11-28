import AVFoundation
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// As soon as it is created it starts encoding the PNG in the background and
/// writes it to a working file. Once that succeeds, only metadata stays in
/// memory. Copy, Save and the editor read the file when they need it.
///
/// A recording comes with its MP4 already written.
final class PendingCapture {
    struct File: Sendable {
        let data: Data
        let url: URL
    }

    enum Kind: Equatable {
        case screenshot
        case recording(duration: TimeInterval)
    }

    let kind: Kind
    let pointSize: CGSize
    let capturedAt: Date
    var screenFrame: CGRect?
    private let scale: CGFloat
    private var original: Screenshot?

    private enum Backing {
        case preparing(Task<URL, Error>)
        case ready(URL)
    }
    private var backing: Backing

    /// The file, once it is ready. Drag and drop needs the answer right away
    /// and cannot wait, so it reads this instead of awaiting `fileURL()`.
    var readyFileURL: URL? {
        guard case .ready(let url) = backing else { return nil }
        return url
    }

    init(screenshot: Screenshot, storage: CaptureStorage) {
        kind = .screenshot
        pointSize = screenshot.pointSize
        capturedAt = screenshot.capturedAt
        screenFrame = screenshot.screenFrame
        scale = screenshot.scale
        original = screenshot
        // Each capture gets a folder of its own, so the file inside can
        // carry the plain name it will have wherever it is dropped.
        backing = .preparing(Task {
            let data = try await ScreenshotWriter.pngData(for: screenshot)
            let url = try storage.makeCaptureDirectory()
                .appending(path: ScreenshotWriter.fileName(capturedAt: screenshot.capturedAt))
            try await Self.write(data, to: url)
            return url
        })
        Task {
            _ = try? await fileURL()
        }
    }

    init(recording: Recording) {
        kind = .recording(duration: recording.duration)
        pointSize = recording.pointSize
        capturedAt = recording.capturedAt
        scale = 1
        backing = .ready(recording.url)
    }

    /// The recording, for a capture that is one, once its file is ready.
    var recording: Recording? {
        guard case .recording(let duration) = kind, let url = readyFileURL else { return nil }
        return Recording(url: url, pointSize: pointSize, duration: duration, capturedAt: capturedAt)
    }

    /// `screenScale` stands in for the pixels per point of a recording,
    /// which its file does not say.
    init(
        restoring file: URL,
        storage: CaptureStorage,
        screenScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
    ) throws {
        if file.pathExtension == "mp4" {
            guard let info = RecordingFileInfo(contentsOf: file) else {
                throw CaptureError.cannotReadRecording(file)
            }
            kind = .recording(duration: info.duration)
            scale = screenScale
            pointSize = CGSize(width: info.pixelSize.width / screenScale, height: info.pixelSize.height / screenScale)
            capturedAt = try file.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date()
            backing = .ready(try storage.restore(file))
            return
        }
        guard try Self.hasPNGEnd(at: file),
              let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              CGImageSourceGetType(source) == UTType.png.identifier as CFString,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            throw CaptureError.cannotReadFile(file)
        }
        let dpi = properties[kCGImagePropertyDPIWidth] as? CGFloat ?? 72
        // PNG stores pixels per metre, so Retina density may round to just under 144 dpi.
        scale = max(1, (dpi / 72).rounded())
        pointSize = CGSize(width: width / scale, height: height / scale)
        capturedAt = try file.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date()
        kind = .screenshot
        backing = .ready(try storage.restore(file))
    }

    private static func hasPNGEnd(at url: URL) throws -> Bool {
        // ImageIO can decode a partially written PNG and still report success.
        let endChunk = Data([0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        guard size >= endChunk.count else { return false }
        try file.seek(toOffset: size - UInt64(endChunk.count))
        return try file.read(upToCount: endChunk.count) == endChunk
    }

    func file() async throws -> File {
        let url = try await fileURL()
        return File(data: try await Self.readData(from: url), url: url)
    }

    /// Keeps the original if writing fails: it may be the only copy left.
    func fileURL() async throws -> URL {
        switch backing {
        case .ready(let url):
            return url
        case .preparing(let task):
            let url = try await task.value
            original = nil
            backing = .ready(url)
            return url
        }
    }

    func screenshot() async throws -> Screenshot {
        let image: CGImage
        if let original {
            image = original.image
        } else {
            image = try await Self.readImage(from: fileURL())
        }
        return Screenshot(image: image, scale: scale, capturedAt: capturedAt, screenFrame: screenFrame)
    }

    /// A standalone small bitmap, so a preview never retains a full frame,
    /// of `part` of the screenshot (in points, origin at the top-left
    /// corner), or of all of it.
    func thumbnail(of part: CGRect? = nil, maxPixelSize: Int) async throws -> CGImage {
        if case .recording = kind {
            let frame = try await Self.firstFrame(of: fileURL(), maxPixelSize: part == nil ? maxPixelSize : nil)
            guard let part else { return frame }
            let screenshot = Screenshot(image: frame, scale: CGFloat(frame.width) / pointSize.width, capturedAt: capturedAt)
            return try await Self.resize(screenshot.cropped(to: part)?.image ?? frame, maxPixelSize: maxPixelSize)
        }
        guard let part else {
            if let original {
                return try await Self.resize(original.image, maxPixelSize: maxPixelSize)
            }
            return try await Self.readImage(from: fileURL(), maxPixelSize: maxPixelSize)
        }
        let screenshot: Screenshot
        if let original {
            screenshot = original
        } else {
            // Read only as large as the part needs to fill the thumbnail. At
            // full size, a tall scroll capture would take hundreds of MB.
            let factor = min(CGFloat(maxPixelSize) / (max(part.width, part.height) * scale), 1)
            let longestSide = max(pointSize.width, pointSize.height) * scale * factor
            let image = try await Self.readImage(from: fileURL(), maxPixelSize: Int(longestSide.rounded(.up)))
            screenshot = Screenshot(image: image, scale: CGFloat(image.width) / pointSize.width, capturedAt: capturedAt)
        }
        let image = screenshot.cropped(to: part)?.image ?? screenshot.image
        return try await Self.resize(image, maxPixelSize: maxPixelSize)
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

    /// The recording's first frame, as large as it is, or with its longer
    /// side at most `maxPixelSize`.
    @concurrent
    private static func firstFrame(of url: URL, maxPixelSize: Int?) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let maxPixelSize {
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        }
        do {
            return try await generator.image(at: .zero).image
        } catch {
            throw CaptureError.cannotReadRecording(url)
        }
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

    @concurrent
    private static func write(_ data: Data, to url: URL) async throws {
        try data.write(to: url)
    }
}
