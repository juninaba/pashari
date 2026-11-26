import AVFoundation
import Foundation

enum RecordingFiles {
    /// Moves a recording into `directory`, under the same name, or with
    /// "-2", "-3"... when the name is taken. A recording can be hundreds of
    /// MB: moving it is instant on the same disk, and `@concurrent` keeps
    /// the copy to another disk off the main thread.
    @concurrent
    static func move(_ url: URL, into directory: URL, named name: String? = nil) async throws -> URL {
        let destination = ScreenshotWriter.availableURL(in: directory, named: name ?? url.lastPathComponent)
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
    ///
    /// The cut is made next to the recording, and moved in only once it is
    /// whole: should it fail, nothing in `directory` is touched, and a file
    /// that took the name meanwhile is not written over.
    @concurrent
    static func trim(_ url: URL, to range: CMTimeRange, into directory: URL) async throws {
        let cut = url.deletingLastPathComponent().appending(path: "trimming-\(UUID().uuidString).mp4")
        do {
            try await export(url, range, to: cut)
            _ = try await move(cut, into: directory, named: url.lastPathComponent)
        } catch {
            try? FileManager.default.removeItem(at: cut)
            throw error
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
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let size = try await track.load(.naturalSize)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        // In the video's own colours, which go into the new file as they are.
        let videoOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        let audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: RecordingWriter.audioSampleRate,
                AVNumberOfChannelsKey: RecordingWriter.audioChannelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            audioOutput = output
        } else {
            audioOutput = nil
        }

        guard reader.startReading() else { throw reader.error ?? CaptureError.cannotTrimRecording }

        func nextVideoFrame() -> (frame: CVPixelBuffer, time: CMTime)? {
            while let sample = videoOutput.copyNextSampleBuffer() {
                guard let frame = sample.imageBuffer else { continue }
                return (frame, sample.presentationTimeStamp - range.start)
            }
            return nil
        }

        func nextAudioBuffer() -> (buffer: CMSampleBuffer, time: CMTime)? {
            guard let audioOutput else { return nil }
            while let sample = audioOutput.copyNextSampleBuffer() {
                guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                return (sample, sample.presentationTimeStamp - range.start)
            }
            return nil
        }

        // The frame that shows where the cut begins may have come earlier.
        // It starts the new recording.
        var opening: CVPixelBuffer?
        var pendingVideo: (frame: CVPixelBuffer, time: CMTime)?
        while let candidate = nextVideoFrame() {
            if candidate.time <= .zero {
                opening = candidate.frame
            } else {
                pendingVideo = candidate
                break
            }
        }
        let firstVideo: (frame: CVPixelBuffer, time: CMTime)
        if let frame = opening {
            firstVideo = (frame, .zero)
        } else if let first = pendingVideo {
            firstVideo = first
            pendingVideo = nextVideoFrame()
        } else {
            reader.cancelReading()
            throw CaptureError.cannotTrimRecording
        }

        let writer = try RecordingWriter(
            url: destination,
            width: Int(size.width),
            height: Int(size.height),
            audioSources: audioOutput == nil ? [] : [.system],
            maximumDuration: max(.zero, range.duration - firstVideo.time),
            isRealTime: false
        )
        do {
            try append(firstVideo.frame, at: firstVideo.time, to: writer)

            // Drive whichever track is ready for more media data, preferring
            // the earlier timestamp when both are ready, and mark each track
            // finished as soon as its reader runs dry so a long static screen
            // never blocks the continuous audio track (or vice versa).
            var videoExhausted = pendingVideo == nil
            var videoFinished = false
            var pendingAudio = nextAudioBuffer()
            var audioFinished = audioOutput == nil
            if !audioFinished, pendingAudio == nil {
                try writer.finishAudio(at: range.duration)
                audioFinished = true
            }

            func stepVideo() throws {
                if let video = pendingVideo {
                    try append(video.frame, at: video.time, to: writer)
                    pendingVideo = nextVideoFrame()
                    videoExhausted = pendingVideo == nil
                } else if videoExhausted {
                    try writer.finishVideo(at: range.duration)
                    videoFinished = true
                }
            }

            func stepAudio() throws {
                if let audio = pendingAudio {
                    try writer.appendAudio(audio.buffer, from: .system, at: audio.time)
                    pendingAudio = nextAudioBuffer()
                }
                if pendingAudio == nil {
                    try writer.finishAudio(at: range.duration)
                    audioFinished = true
                }
            }

            var stalledChecks = 0
            while !videoFinished || !audioFinished {
                let canWriteVideo = !videoFinished && writer.isReadyForMoreVideo
                let canWriteAudio = !audioFinished && writer.isReadyForMoreAudio
                if canWriteVideo && canWriteAudio {
                    let videoTime = pendingVideo?.time ?? range.duration
                    let audioTime = pendingAudio?.time ?? range.duration
                    if videoTime <= audioTime {
                        try stepVideo()
                    } else {
                        try stepAudio()
                    }
                    stalledChecks = 0
                } else if canWriteVideo {
                    try stepVideo()
                    stalledChecks = 0
                } else if canWriteAudio {
                    try stepAudio()
                    stalledChecks = 0
                } else {
                    guard writer.isWriting, stalledChecks < 2_000 else {
                        throw CaptureError.cannotTrimRecording
                    }
                    stalledChecks += 1
                    usleep(5_000)
                }
            }
            guard reader.status == .completed else { throw reader.error ?? CaptureError.cannotTrimRecording }
        } catch {
            reader.cancelReading()
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
