import AVFoundation
import CoreVideo

/// Writes the frames of a recording into an MP4 file as they arrive.
///
/// The screen sends a frame only when something in the area changes, so
/// frames come at uneven times, and none at all while nothing moves. Each
/// frame shows until the next one, and the last one until the recording
/// stops.
///
/// It is used from one queue at a time, the recorder's (`@unchecked
/// Sendable` tells Swift that this was checked by hand).
nonisolated final class RecordingWriter: @unchecked Sendable {
    enum Outcome: Equatable {
        case appended
        /// The encoder was still busy with earlier frames, or the frame
        /// came out of order.
        case dropped
        /// The recording is as long as it may get. The frame was not added.
        case full
    }

    /// Recordings stop at five minutes.
    static let maximumDuration = CMTime(value: 300, timescale: 1)
    static let audioSampleRate = AudioMixer.sampleRate
    static let audioChannelCount = AudioMixer.channelCount

    let url: URL
    private let maximumDuration: CMTime
    private let isRealTime: Bool
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private let audioMixer: AudioMixer?
    private var startTime: CMTime?
    private var lastFrame: (buffer: CVPixelBuffer, time: CMTime)?
    private var isVideoFinished = false
    private var isAudioFinished = false
    private var finalEndTime: CMTime?

    var isReadyForMoreVideo: Bool { !isVideoFinished && input.isReadyForMoreMediaData }
    var isReadyForMoreAudio: Bool { !isAudioFinished && (audioInput?.isReadyForMoreMediaData ?? false) }
    var isWriting: Bool { writer.status == .writing }

    /// `width` and `height` are the frames' size in pixels. While
    /// recording (`isRealTime`), a frame the encoder has no room for is
    /// dropped: the screen does not wait. Encoding a recording that
    /// exists, as trimming does, each frame waits for room instead.
    ///
    /// Pass non-empty `audioSources` to add a stereo 48 kHz AAC audio track.
    init(
        url: URL,
        width: Int,
        height: Int,
        audioSources: Set<AudioMixer.Source> = [],
        maximumDuration: CMTime = RecordingWriter.maximumDuration,
        isRealTime: Bool = true
    ) throws {
        self.url = url
        self.maximumDuration = maximumDuration
        self.isRealTime = isRealTime
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // The index goes at the front of the file, so that a browser can
        // start playing it before all of it has arrived.
        writer.shouldOptimizeForNetworkUse = true
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Self.outputSettings(width: width, height: height)
        )
        input.expectsMediaDataInRealTime = isRealTime
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)

        if audioSources.isEmpty {
            audioInput = nil
            audioMixer = nil
        } else {
            let audio = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: Self.audioOutputSettings()
            )
            audio.expectsMediaDataInRealTime = isRealTime
            guard writer.canAdd(audio) else { throw CocoaError(.fileWriteUnknown) }
            writer.add(audio)
            audioInput = audio
            audioMixer = try AudioMixer(sources: audioSources, maximumDuration: maximumDuration)
        }
    }

    /// Adds a frame that shows from `time` on. The first frame starts the
    /// recording.
    func append(_ buffer: CVPixelBuffer, at time: CMTime) throws -> Outcome {
        let start: CMTime
        if let startTime {
            start = startTime
        } else {
            guard writer.startWriting() else { throw failure }
            writer.startSession(atSourceTime: time)
            startTime = time
            start = time
        }
        guard time - start < maximumDuration else { return .full }
        if let lastFrame, time <= lastFrame.time { return .dropped }
        guard input.isReadyForMoreMediaData || (!isRealTime && waitUntilReady(input, seconds: 10)) else { return .dropped }
        guard adaptor.append(buffer, withPresentationTime: time) else { throw failure }
        lastFrame = (buffer, time)
        return .appended
    }

    /// Adds PCM audio from `source`. Audio arriving before the first video
    /// frame or when no audio track was configured is ignored.
    func appendAudio(
        _ sampleBuffer: CMSampleBuffer,
        from source: AudioMixer.Source = .system,
        at presentationTime: CMTime? = nil
    ) throws {
        guard let audioInput, let audioMixer, let startTime, !isAudioFinished, writer.status == .writing else { return }
        let time = presentationTime ?? sampleBuffer.presentationTimeStamp
        try audioMixer.append(sampleBuffer, from: source, at: time, startTime: startTime) { chunk in
            try writeAudioChunk(chunk, to: audioInput, waitSeconds: isRealTime ? 0 : 10)
        }
    }

    /// Ends the video track at `time` (appending the last frame as a hold
    /// frame if needed) and marks the video input finished so an offline
    /// audio track can keep writing past a static screen.
    func finishVideo(at time: CMTime) throws {
        guard !isVideoFinished, let startTime, let lastFrame else { return }
        let end = max(min(time, startTime + maximumDuration), lastFrame.time)
        // The file says how long each frame shows by when the next one
        // starts. Without one more at the end, the last frame would get the
        // length of a single frame, and some players would show nothing for
        // the rest of the recording. This one only ends the last.
        if end > lastFrame.time {
            let ended = waitUntilReady(input, seconds: isRealTime ? 1 : 10)
                && adaptor.append(lastFrame.buffer, withPresentationTime: end)
            // A recording is kept without it, its last frame then showing
            // only briefly. A recording encoded anew must be whole, or the
            // one it comes from stays as it is.
            if !ended, !isRealTime {
                throw failure
            }
        }
        self.lastFrame = nil
        finalEndTime = end
        isVideoFinished = true
        input.markAsFinished()
    }

    /// Flushes remaining audio up to `time` and marks the audio input finished.
    func finishAudio(at time: CMTime) throws {
        guard !isAudioFinished, let audioInput, let audioMixer, let startTime else { return }
        let end = min(time, startTime + maximumDuration)
        defer {
            isAudioFinished = true
            audioInput.markAsFinished()
        }
        try audioMixer.flush(upTo: end, startTime: startTime) { chunk in
            try writeAudioChunk(chunk, to: audioInput, waitSeconds: isRealTime ? 1 : 10)
        }
    }

    /// Ends the file at `time`, or `maximumDuration` after the first frame if
    /// that comes first, with the last frame showing until then. Gives how
    /// long the recording is, or nil when no frame came, in which case
    /// there is no file.
    func finish(at time: CMTime, completion: @escaping @Sendable (Result<TimeInterval?, Error>) -> Void) {
        guard let startTime, lastFrame != nil || isVideoFinished else {
            cancel()
            completion(.success(nil))
            return
        }
        do {
            try finishVideo(at: time)
        } catch {
            cancel()
            completion(.failure(error))
            return
        }
        let end = finalEndTime ?? min(time, startTime + maximumDuration)
        if audioInput != nil {
            do {
                try finishAudio(at: end)
            } catch {
                if !isRealTime {
                    cancel()
                    completion(.failure(error))
                    return
                }
                Log.capture.error("Recording audio could not be flushed: \(error.localizedDescription, privacy: .public)")
            }
        }
        writer.endSession(atSourceTime: end)
        writer.finishWriting { [self] in
            guard writer.status == .completed else {
                let error = failure
                try? FileManager.default.removeItem(at: url)
                completion(.failure(error))
                return
            }
            completion(.success((end - startTime).seconds))
        }
    }

    /// Stops writing and deletes the file.
    func cancel() {
        if writer.status == .writing {
            writer.cancelWriting()
        }
        audioMixer?.reset()
        lastFrame = nil
        isVideoFinished = false
        isAudioFinished = false
        finalEndTime = nil
        try? FileManager.default.removeItem(at: url)
    }

    private var failure: Error {
        writer.error ?? CocoaError(.fileWriteUnknown)
    }

    private func writeAudioChunk(
        _ sampleBuffer: CMSampleBuffer,
        to audioInput: AVAssetWriterInput,
        waitSeconds: Int
    ) throws -> Bool {
        if waitSeconds == 0 {
            guard audioInput.isReadyForMoreMediaData else { return false }
        } else {
            guard waitUntilReady(audioInput, seconds: waitSeconds) else {
                if !isRealTime { throw failure }
                return false
            }
        }
        guard audioInput.append(sampleBuffer) else { throw failure }
        return true
    }

    /// The encoder takes a moment for the frames before. A writer that
    /// failed is never ready again.
    private func waitUntilReady(_ writerInput: AVAssetWriterInput, seconds: Int) -> Bool {
        for _ in 0..<(seconds * 200) {
            if writerInput.isReadyForMoreMediaData { return true }
            guard writer.status == .writing else { return false }
            usleep(5_000)
        }
        return false
    }

    /// Stereo 48 kHz AAC at 128 kbit/s: universally supported by QuickTime,
    /// browsers and messaging apps such as Slack.
    private static func audioOutputSettings() -> [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: audioChannelCount,
            AVChannelLayoutKey: layoutData,
            AVEncoderBitRateKey: 128_000,
        ]
    }

    /// H.264, which every player and browser plays. The quality is set
    /// rather than a bit rate: text stays as sharp while it scrolls as
    /// a fixed 8 or 16 Mbit/s keeps it, in about two thirds of the size,
    /// and a screen that stands still costs next to nothing.
    ///
    /// A key frame at least every two seconds lets players seek. Frames
    /// stay in order: the encoder would otherwise hold a frame back until
    /// the next one comes, which on a screen that stands still can be long.
    private static func outputSettings(width: Int, height: Int) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoQualityKey: 0.75,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: 60,
            ],
        ]
    }
}
