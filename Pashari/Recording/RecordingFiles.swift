import AVFoundation
import Foundation

enum RecordingFiles {
    /// Moves a recording into `directory`, under the same name, or with
    /// "-2", "-3"... when the name is taken. A recording can be hundreds of
    /// MB: moving it is instant on the same disk, and `@concurrent` keeps
    /// the copy to another disk off the main thread.
    @concurrent
    static func move(_ url: URL, into directory: URL) async throws -> URL {
        let destination = ScreenshotWriter.availableURL(in: directory, named: url.lastPathComponent)
        do {
            // Fails rather than replace a file that took the name meanwhile.
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            throw CaptureError.cannotSaveRecording(destination)
        }
        return destination
    }

    /// Cuts the recording at `url` down to `range`, in place.
    @concurrent
    static func trim(_ url: URL, to range: CMTimeRange) async throws {
        // Next to the recording, in its own folder, and not named like one,
        // so that it is never taken for a recording to restore.
        let trimmed = url.deletingLastPathComponent().appending(path: "trimming-\(UUID().uuidString).mp4")
        do {
            try await export(url, range, to: trimmed)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: trimmed)
        } catch {
            try? FileManager.default.removeItem(at: trimmed)
            throw CaptureError.cannotTrimRecording
        }
    }

    /// Cuts the recording at `url` down to `range` into `directory`, under
    /// the same name, or with "-2", "-3"... when the name is taken. The
    /// recording itself stays as it is.
    @concurrent
    static func trim(_ url: URL, to range: CMTimeRange, into directory: URL) async throws {
        let destination = ScreenshotWriter.availableURL(in: directory, named: url.lastPathComponent)
        do {
            try await export(url, range, to: destination)
        } catch {
            throw CaptureError.cannotSaveRecording(destination)
        }
    }

    /// Encodes `range` of the recording at `url` anew into `destination`,
    /// as a recording is encoded. Copying the frames as they are would be
    /// quicker, but would leave those cut away since the last key frame in
    /// the file, only hidden: what was cut away could be seen again.
    @concurrent
    private static func export(_ url: URL, _ range: CMTimeRange, to destination: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptureError.cannotTrimRecording
        }
        let size = try await track.load(.naturalSize)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        // In the video's own colours, which go into the new file as they are.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CaptureError.cannotTrimRecording }

        let writer = try RecordingWriter(
            url: destination,
            width: Int(size.width),
            height: Int(size.height),
            isRealTime: false
        )
        do {
            // The frame that shows where the cut begins may have come
            // earlier. It starts the new recording.
            var opening: CVPixelBuffer?
            while let sample = output.copyNextSampleBuffer() {
                guard let frame = sample.imageBuffer else { continue }
                let time = sample.presentationTimeStamp - range.start
                if time <= .zero {
                    opening = frame
                    continue
                }
                if let frame = opening {
                    try append(frame, at: .zero, to: writer)
                    opening = nil
                }
                try append(frame, at: time, to: writer)
            }
            if let frame = opening {
                try append(frame, at: .zero, to: writer)
            }
            guard reader.status == .completed else { throw reader.error ?? CaptureError.cannotTrimRecording }
        } catch {
            writer.cancel()
            throw error
        }
        let duration = try await withCheckedThrowingContinuation { continuation in
            writer.finish(at: range.duration) { continuation.resume(with: $0) }
        }
        guard duration != nil else { throw CaptureError.cannotTrimRecording }
    }

    nonisolated private static func append(_ frame: CVPixelBuffer, at time: CMTime, to writer: RecordingWriter) throws {
        guard try writer.append(frame, at: time) == .appended else { throw CaptureError.cannotTrimRecording }
    }
}
