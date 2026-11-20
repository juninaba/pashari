import CoreMedia
import ScreenCaptureKit

/// Records an area of a display into an MP4 file: what happens there, the
/// pointer and its clicks included, with Pashari's own panels left out.
///
/// ScreenCaptureKit hands over the frames on `queue`, a thread of their own,
/// and `writer` is only touched there, which is what makes it safe to share
/// this object between threads (`@unchecked Sendable` tells Swift that this
/// was checked by hand).
nonisolated final class AreaRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// The longer side of a recording, in pixels: the most the Mac's H.264
    /// encoder takes. Only an area of a 5K or 6K display is wider, and it
    /// is recorded a little smaller.
    static let maximumSide = 4096

    let url: URL
    let width: Int
    let height: Int

    private let queue = DispatchQueue(label: "io.github.juninaba.pashari.area-recorder", qos: .userInteractive)
    private var stream: SCStream?
    private let onStart: @Sendable () -> Void
    private let onFailure: @Sendable (Error) -> Void

    // On `queue`.
    private let writer: RecordingWriter
    private var hasStarted = false
    private var hasFailed = false

    /// `area` is in points, with the origin at the display's top-left
    /// corner, and must lie on whole points: ScreenCaptureKit would scale
    /// the frames of any other area, which blurs them. `filter` is what to
    /// record of the display, see `ScreenCapturer.recordingFilter`.
    /// `onStart` is called with the first frame, which is where the
    /// recording begins.
    init(
        area: CGRect,
        filter: SCContentFilter,
        url: URL,
        onStart: @escaping @Sendable () -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) throws {
        let size = Self.pixelSize(of: area.size, scale: CGFloat(filter.pointPixelScale))
        self.url = url
        width = size.width
        height = size.height
        writer = try RecordingWriter(url: url, width: size.width, height: size.height)
        self.onStart = onStart
        self.onFailure = onFailure
        super.init()

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = area
        configuration.width = size.width
        configuration.height = size.height
        configuration.captureResolution = .best
        // The circles around clicks are only drawn into BGRA frames. The
        // encoder turns them into video colours itself.
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // In the display's own colours, which the encoder would take for
        // video colours: red came out orange and green yellowish. In sRGB,
        // the encoder converts them, and the video matches a screenshot.
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = true
        if #available(macOS 15.0, *) {
            configuration.showMouseClicks = true
        }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        // A few frames for the encoder to work on while new ones arrive.
        // Each frame of a large area takes tens of MB.
        configuration.queueDepth = 6
        stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    }

    /// The video's size in pixels for an area of `size` points: the area's
    /// own pixels, at most `maximumSide` long, and even, because video
    /// stores colour for blocks of two by two pixels.
    static func pixelSize(of size: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        let width = size.width * scale
        let height = size.height * scale
        let factor = min(1, CGFloat(maximumSide) / max(width, height, 1))
        func even(_ length: CGFloat) -> Int {
            max(2, Int((length * factor + 0.001) / 2) * 2)
        }
        return (even(width), even(height))
    }

    /// How much of the recording is on disk so far, in bytes. While
    /// recording, AVFoundation writes into a file of its own next to `url`,
    /// and moves it there only once it is finished.
    nonisolated static func bytesWritten(to url: URL) -> Int {
        let folder = url.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(url.lastPathComponent) }
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .reduce(0, +)
    }

    func start() async throws {
        guard let stream else { return }
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            // The stream holds on to this object as its output.
            self.stream = nil
            queue.async { self.writer.cancel() }
            throw error
        }
    }

    /// Stops recording and finishes the file. Gives the recording's length,
    /// or nil when not a single frame came, in which case there is no file.
    func stop() async throws -> TimeInterval? {
        // Now, not once the stream has stopped: the recording ends when
        // asked to.
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        try? await stream?.stopCapture()
        stream = nil
        // Frames that arrived before the stop may still wait on the queue.
        // This runs after them.
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.writer.finish(at: end) { continuation.resume(with: $0) }
            }
        }
    }

    /// Stops recording and deletes the file.
    func cancel() async {
        try? await stream?.stopCapture()
        stream = nil
        await withCheckedContinuation { continuation in
            queue.async {
                self.writer.cancel()
                continuation.resume()
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard
            type == .screen,
            !hasFailed,
            sampleBuffer.hasNewScreenFrame,
            let pixelBuffer = sampleBuffer.imageBuffer,
            CVPixelBufferGetWidth(pixelBuffer) == width,
            CVPixelBufferGetHeight(pixelBuffer) == height
        else { return }

        do {
            let outcome = try writer.append(pixelBuffer, at: sampleBuffer.presentationTimeStamp)
            if outcome == .appended, !hasStarted {
                hasStarted = true
                onStart()
            }
        } catch {
            hasFailed = true
            Log.capture.error("Recording could not be written: \(error.localizedDescription, privacy: .public)")
            onFailure(error)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.capture.error("Recording stopped: \(error.localizedDescription, privacy: .public)")
        onFailure(error)
    }
}
