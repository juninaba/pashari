import AVFoundation
import CoreVideo
import Testing

@testable import Pashari

/// Frames and MP4 files for tests, made and read without the screen.
enum TestVideos {
    /// A frame like the ones the screen sends: BGRA, on an IOSurface,
    /// filled with one colour.
    static func frame(width: Int, height: Int, color: TestImages.RGBA) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        let frame = buffer!
        CVBufferSetAttachment(
            frame,
            kCVImageBufferCGColorSpaceKey,
            CGColorSpace(name: CGColorSpace.sRGB)!,
            .shouldPropagate
        )
        CVPixelBufferLockBaseAddress(frame, [])
        let bytesPerRow = CVPixelBufferGetBytesPerRow(frame)
        let pixels = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = color.blue
                pixels[offset + 1] = color.green
                pixels[offset + 2] = color.red
                pixels[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        return frame
    }

    /// Writes an MP4 of `frames`, each showing from its time in seconds,
    /// that ends at `end`, and gives its length.
    @discardableResult
    static func makeMP4(
        at url: URL,
        width: Int = 64,
        height: Int = 48,
        frames: [(color: TestImages.RGBA, time: Double)],
        end: Double
    ) async throws -> TimeInterval? {
        let writer = try RecordingWriter(url: url, width: width, height: height)
        for frame in frames {
            // The encoder keeps up with real time only; tests send faster.
            var outcome = RecordingWriter.Outcome.dropped
            for _ in 0..<200 {
                outcome = try writer.append(
                    Self.frame(width: width, height: height, color: frame.color),
                    at: time(frame.time)
                )
                guard outcome == .dropped else { break }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        return try await finish(writer, at: end)
    }

    static func finish(_ writer: RecordingWriter, at end: Double) async throws -> TimeInterval? {
        try await withCheckedThrowingContinuation { continuation in
            writer.finish(at: time(end)) { continuation.resume(with: $0) }
        }
    }

    /// A time as the screen gives it: the host clock, in nanoseconds.
    static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: 1_000 + seconds, preferredTimescale: 1_000_000_000)
    }

    struct Sample: Equatable {
        let time: Double
        let duration: Double
    }

    /// The frames in the file, each with when it starts and how long it
    /// shows, in seconds from the start.
    static func samples(in url: URL) async throws -> [Sample] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var samples: [Sample] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(buffer) > 0 else { continue }
            samples.append(Sample(time: buffer.presentationTimeStamp.seconds, duration: buffer.duration.seconds))
        }
        return samples
    }

    /// The picture the file shows `seconds` from the start.
    static func image(in url: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    static func temporaryURL(named name: String = "recording.mp4") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "PashariTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: name)
    }
}
