import CoreMedia
import ScreenCaptureKit

/// Records an area of a display while the user scrolls it, and joins the
/// frames into one picture with `ScrollStitcher` as they arrive.
///
/// ScreenCaptureKit hands over the frames on `queue`, a thread of their own,
/// so that joining them never holds up the screen. Everything below marked
/// "on `queue`" is only touched there, which is what makes it safe to share
/// this object between threads (`@unchecked Sendable` tells Swift that this
/// was checked by hand).
nonisolated final class ScrollRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Progress: Equatable, Sendable {
        /// The picture's height so far, in pixels.
        var pictureHeight: Int
        /// True while the frames cannot be placed, most likely because the
        /// content is scrolled too fast.
        var isLost = false
        /// True once the picture is as tall as it may get.
        var isFull = false
    }

    /// How much of the area's right edge is left out when frames are
    /// compared, in points: room for a scroll bar.
    private static let scrollBarWidth: CGFloat = 16

    /// The tallest picture, in pixels, for a given width. Every row is kept
    /// uncompressed until the end, so without a limit a long page could
    /// fill the memory: this allows about 240 MB.
    static func maximumHeight(forWidth width: Int) -> Int {
        min(30_000, 60_000_000 / max(width, 1))
    }

    /// Pixels per point of the frames.
    let scale: CGFloat

    private let queue = DispatchQueue(label: "io.github.juninaba.pashari.scroll-recorder", qos: .userInteractive)
    private var stream: SCStream?
    private let fallbackColorSpace: CGColorSpace
    private let onProgress: @Sendable (Progress) -> Void
    private let onFailure: @Sendable (Error) -> Void

    // On `queue`.
    private var stitcher: ScrollStitcher
    private var colorSpace: CGColorSpace?
    private var progress: Progress

    /// `area` is in points, with the origin at the display's top-left
    /// corner, and must lie on whole points: ScreenCaptureKit would scale
    /// the frames of any other area, which blurs them, and then no two of
    /// them line up. `filter` is what to record of `display`, see
    /// `ScreenCapturer.recordingFilter`.
    init(
        area: CGRect,
        of display: SCDisplay,
        filter: SCContentFilter,
        onProgress: @escaping @Sendable (Progress) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = area
        configuration.width = Int((area.width * scale).rounded())
        configuration.height = Int((area.height * scale).rounded())
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 5

        stitcher = ScrollStitcher(
            width: configuration.width,
            height: configuration.height,
            maximumHeight: Self.maximumHeight(forWidth: configuration.width),
            ignoringRightColumns: Int((Self.scrollBarWidth * scale).rounded())
        )
        progress = Progress(pictureHeight: 0)
        fallbackColorSpace = CGDisplayCopyColorSpace(display.displayID)
        self.onProgress = onProgress
        self.onFailure = onFailure
        super.init()
        stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    }

    func start() async throws {
        guard let stream else { return }
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            // The stream holds on to this object as its output.
            self.stream = nil
            throw error
        }
    }

    /// Stops recording and throws away what was recorded.
    func cancel() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    /// Stops recording and returns the picture: everything placed so far.
    func stop() async -> CGImage? {
        try? await stream?.stopCapture()
        stream = nil
        // Frames that arrived before the stop may still wait on the queue.
        // This runs after them.
        return await withCheckedContinuation { continuation in
            queue.async {
                let colorSpace = self.colorSpace ?? self.fallbackColorSpace
                continuation.resume(returning: self.stitcher.makeImage(colorSpace: colorSpace))
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
            Self.hasNewFrame(sampleBuffer),
            let pixelBuffer = sampleBuffer.imageBuffer,
            CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
            CVPixelBufferGetWidth(pixelBuffer) == stitcher.width,
            CVPixelBufferGetHeight(pixelBuffer) == stitcher.height
        else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let pixels = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        if colorSpace == nil {
            colorSpace = Self.colorSpace(of: pixelBuffer)
        }
        let outcome = stitcher.add(
            ScrollStitcher.Frame(
                width: stitcher.width,
                height: stitcher.height,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                pixels: UnsafeRawPointer(pixels)
            )
        )
        report(outcome)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.capture.error("Scroll recording stopped: \(error.localizedDescription, privacy: .public)")
        onFailure(error)
    }

    // MARK: - Helpers

    private func report(_ outcome: ScrollStitcher.Outcome) {
        var newProgress = progress
        newProgress.pictureHeight = stitcher.pictureHeight
        newProgress.isFull = outcome == .full
        switch outcome {
        case .lost:
            // Told at once: frames come only when the screen changes, so
            // after a jump that went too far there may be no second one.
            newProgress.isLost = true
        case .ignored:
            break
        case .started, .unchanged, .scrolled, .changedInPlace, .full:
            newProgress.isLost = false
        }

        guard newProgress != progress else { return }
        if newProgress.isLost != progress.isLost {
            let change = newProgress.isLost ? "lost track of" : "found"
            Log.capture.info("Scroll recording \(change, privacy: .public) the content")
        }
        progress = newProgress
        onProgress(newProgress)
    }

    /// ScreenCaptureKit also delivers buffers with no new picture, for
    /// instance when nothing on screen changed.
    private static func hasNewFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        // `.started` marks the very first frame.
        return status == .complete || status == .started
    }

    /// The frames come in the display's colour space unless told otherwise,
    /// and say which one that is.
    private static func colorSpace(of pixelBuffer: CVPixelBuffer) -> CGColorSpace? {
        if let colorSpace = CVImageBufferGetColorSpace(pixelBuffer)?.takeUnretainedValue() {
            return colorSpace
        }
        guard let attachments = CVBufferCopyAttachments(pixelBuffer, .shouldPropagate) else { return nil }
        return CVImageBufferCreateColorSpaceFromAttachments(attachments)?.takeRetainedValue()
    }
}
