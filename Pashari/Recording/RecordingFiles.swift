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

    /// Cuts the recording at `url` down to `range`, in place. The frames
    /// are copied as they are, which takes a moment even for a long
    /// recording; the file says where to start, and players, browsers
    /// included, begin there.
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

    @concurrent
    private static func export(_ url: URL, _ range: CMTimeRange, to destination: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw CaptureError.cannotTrimRecording
        }
        session.timeRange = range
        session.shouldOptimizeForNetworkUse = true
        if #available(macOS 15.0, *) {
            try await session.export(to: destination, as: .mp4)
        } else {
            session.outputURL = destination
            session.outputFileType = .mp4
            await session.export()
            if let error = session.error { throw error }
        }
    }
}
