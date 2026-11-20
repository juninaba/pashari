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

    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var startTime: CMTime?
    private var lastFrame: (buffer: CVPixelBuffer, time: CMTime)?

    /// `width` and `height` are the frames' size in pixels.
    init(url: URL, width: Int, height: Int) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // The index goes at the front of the file, so that a browser can
        // start playing it before all of it has arrived.
        writer.shouldOptimizeForNetworkUse = true
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Self.outputSettings(width: width, height: height)
        )
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)
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
        guard time - start < Self.maximumDuration else { return .full }
        if let lastFrame, time <= lastFrame.time { return .dropped }
        guard input.isReadyForMoreMediaData else { return .dropped }
        guard adaptor.append(buffer, withPresentationTime: time) else { throw failure }
        lastFrame = (buffer, time)
        return .appended
    }

    /// Ends the file at `time`, or five minutes after the first frame if
    /// that comes first, with the last frame showing until then. Gives how
    /// long the recording is, or nil when no frame came, in which case
    /// there is no file.
    func finish(at time: CMTime, completion: @escaping @Sendable (Result<TimeInterval?, Error>) -> Void) {
        guard let startTime, let lastFrame else {
            cancel()
            completion(.success(nil))
            return
        }
        let end = max(min(time, startTime + Self.maximumDuration), lastFrame.time)
        // The file says how long each frame shows by when the next one
        // starts. Without one more at the end, the last frame would get the
        // length of a single frame, and some players would show nothing for
        // the rest of the recording. This one only ends the last.
        if end > lastFrame.time, waitUntilReady() {
            adaptor.append(lastFrame.buffer, withPresentationTime: end)
        }
        self.lastFrame = nil
        input.markAsFinished()
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
        lastFrame = nil
        try? FileManager.default.removeItem(at: url)
    }

    private var failure: Error {
        writer.error ?? CocoaError(.fileWriteUnknown)
    }

    /// The encoder takes a moment for the frames before the last one.
    private func waitUntilReady() -> Bool {
        for _ in 0..<200 {
            if input.isReadyForMoreMediaData { return true }
            usleep(5_000)
        }
        return false
    }

    /// H.264, which every player and browser plays. The quality is set
    /// rather than a bit rate: text stays as sharp while it scrolls as
    /// a fixed 8 or 16 Mbit/s keeps it, in about two thirds of the size,
    /// and a screen that stands still costs next to nothing.
    ///
    /// A key frame at least every two seconds lets players seek, and
    /// without frames out of order, a recording can be cut at any frame.
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
