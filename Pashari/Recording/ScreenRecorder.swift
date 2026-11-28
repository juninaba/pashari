import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Records a display, an area, or a single window into an MP4 file: what
/// happens there, the pointer included, with Pashari's own panels left
/// out, and optionally system audio and microphone input.
///
/// ScreenCaptureKit (and AVFoundation's microphone fallback on macOS 14) hand
/// over samples on `queue`, a thread of their own, and `writer` is only
/// touched there, which is what makes it safe to share this object between
/// threads (`@unchecked Sendable` tells Swift that this was checked by hand).
nonisolated final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// The longer side of a recording, in pixels: the most the Mac's H.264
    /// encoder takes. Larger captures are scaled to fit.
    static let maximumSide = 4096

    let url: URL
    let pointSize: CGSize
    let width: Int
    let height: Int
    private(set) var audio: RecordingAudio

    private let queue = DispatchQueue(label: "io.github.juninaba.pashari.screen-recorder", qos: .userInteractive)
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let microphoneDevice: AVCaptureDevice?
    private var stream: SCStream?
    private var microphoneCapture: MicrophoneCapture?
    private let onStart: @Sendable () -> Void
    private let onFailure: @Sendable (Error) -> Void

    // On `queue`.
    private let writer: RecordingWriter
    private var activeStreamID: ObjectIdentifier?
    private var hasStarted = false
    private var hasFailed = false
    /// When the recording ended. Stopping can come later, say once a
    /// dialog that opened meanwhile has closed; frames after this are left
    /// out.
    private var endTime: CMTime?

    /// With no `area`, records the entire display. An area starts at the
    /// display's top-left origin and must lie on whole points to avoid
    /// blurring. See `ScreenCapturer.recordingFilter` for the display filter.
    /// `onStart` is called with the first frame, which is where the
    /// recording begins.
    convenience init(
        area: CGRect? = nil,
        filter: SCContentFilter,
        url: URL,
        audio: RecordingAudio = .none,
        onStart: @escaping @Sendable () -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) throws {
        let (effectiveAudio, microphoneDevice) = Self.resolveAudioDevice(for: audio)
        let scale = CGFloat(filter.pointPixelScale)
        let pointSize = area?.size ?? filter.contentRect.size
        let size = Self.pixelSize(of: pointSize, scale: scale)
        let configuration = Self.makeConfiguration(width: size.width, height: size.height, audio: effectiveAudio)
        if let area {
            configuration.sourceRect = Self.sourceRect(
                of: area,
                width: size.width,
                height: size.height,
                scale: scale
            )
        }
        try self.init(
            filter: filter,
            configuration: configuration,
            pointSize: pointSize,
            width: size.width,
            height: size.height,
            url: url,
            audio: effectiveAudio,
            microphoneDevice: microphoneDevice,
            onStart: onStart,
            onFailure: onFailure
        )
    }

    /// Records one window on its own, without whatever is in front of or
    /// behind it. `onStart` is called with the first frame, which is where
    /// the recording begins.
    convenience init(
        window: SCWindow,
        url: URL,
        audio: RecordingAudio = .none,
        onStart: @escaping @Sendable () -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) throws {
        let (effectiveAudio, microphoneDevice) = Self.resolveAudioDevice(for: audio)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let contentSize = filter.contentRect.size
        let scale = CGFloat(filter.pointPixelScale)
        guard contentSize.width > 0, contentSize.height > 0, scale > 0 else {
            throw CaptureError.windowNotFound
        }
        let size = Self.pixelSize(of: contentSize, scale: scale)
        let configuration = Self.makeConfiguration(width: size.width, height: size.height, audio: effectiveAudio)
        configuration.ignoreShadowsSingleWindow = true
        // Keep recording the whole window even if the user drags part of it
        // past the edge of a display.
        configuration.ignoreGlobalClipSingleWindow = true
        // When the window is resized mid-recording, fit it inside the video's
        // size without stretching it, rather than clipping it.
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        try self.init(
            filter: filter,
            configuration: configuration,
            pointSize: contentSize,
            width: size.width,
            height: size.height,
            url: url,
            audio: effectiveAudio,
            microphoneDevice: microphoneDevice,
            onStart: onStart,
            onFailure: onFailure
        )
    }

    private init(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        pointSize: CGSize,
        width: Int,
        height: Int,
        url: URL,
        audio: RecordingAudio,
        microphoneDevice: AVCaptureDevice?,
        onStart: @escaping @Sendable () -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) throws {
        self.url = url
        self.pointSize = pointSize
        self.width = width
        self.height = height
        self.audio = audio
        self.filter = filter
        self.configuration = configuration
        self.microphoneDevice = microphoneDevice
        writer = try RecordingWriter(url: url, width: width, height: height, audioSources: audio.sources)
        self.onStart = onStart
        self.onFailure = onFailure
        super.init()
        stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    }

    private static func resolveAudioDevice(for audio: RecordingAudio) -> (RecordingAudio, AVCaptureDevice?) {
        guard audio.microphone else { return (audio, nil) }
        guard let device = AVCaptureDevice.default(for: .audio) else {
            Log.capture.info("No microphone available; recording without microphone")
            return (RecordingAudio(systemAudio: audio.systemAudio, microphone: false), nil)
        }
        return (audio, device)
    }

    /// What ScreenCaptureKit hands over: frames of `width` × `height`
    /// pixels with the pointer in them, and the sound `audio` asks for.
    static func makeConfiguration(
        width: Int,
        height: Int,
        audio: RecordingAudio
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.captureResolution = .best
        // RGB frames, which the encoder turns into video colours itself.
        // Only these, in sRGB (below), were checked against screenshots.
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // In the display's own colours, which the encoder would take for
        // video colours: red came out orange and green yellowish. In sRGB,
        // the encoder converts them, and the video matches a screenshot.
        configuration.colorSpaceName = CGColorSpace.sRGB
        // The pointer, but no rings around clicks (`showMouseClicks`).
        configuration.showsCursor = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        // A few frames for the encoder to work on while new ones arrive.
        // Each frame of a large area takes tens of MB.
        configuration.queueDepth = 6
        if audio.systemAudio {
            configuration.capturesAudio = true
            configuration.sampleRate = RecordingWriter.audioSampleRate
            configuration.channelCount = RecordingWriter.audioChannelCount
            configuration.excludesCurrentProcessAudio = true
        }
        if audio.microphone {
            if #available(macOS 15.0, *) {
                configuration.captureMicrophone = true
            }
        }
        return configuration
    }

    /// The video's size in pixels for a capture of `size` points:
    /// its own pixels, at most `maximumSide` long, and even, because video
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

    /// The part of `area` the video shows. On a standard display an area
    /// can be an odd number of pixels across: it loses its last column or
    /// row, rather than having the rest scaled to fit, which would blur it.
    /// A larger area than the encoder takes is scaled down all the same.
    static func sourceRect(of area: CGRect, width: Int, height: Int, scale: CGFloat) -> CGRect {
        let shown = CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        let pixel = 1 / scale + 0.001
        guard shown.width <= area.width, shown.height <= area.height,
              area.width - shown.width <= pixel, area.height - shown.height <= pixel
        else { return area }
        return CGRect(origin: area.origin, size: shown)
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
        let streamID = ObjectIdentifier(stream)
        queue.sync { self.activeStreamID = streamID }
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if audio.systemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            }
            if audio.microphone {
                if #available(macOS 15.0, *) {
                    do {
                        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
                    } catch {
                        Log.capture.warning(
                            "Microphone output could not be added; continuing without microphone: \(error.localizedDescription, privacy: .public)"
                        )
                        try await restartStreamWithoutMicrophone()
                        return
                    }
                } else {
                    await startFallbackMicrophoneCapture(for: stream)
                }
            }
            do {
                try await stream.startCapture()
            } catch {
                if #available(macOS 15.0, *), audio.microphone, Self.isMicrophoneStartError(error) {
                    Log.capture.warning(
                        "Microphone capture failed to start; continuing without microphone: \(error.localizedDescription, privacy: .public)"
                    )
                    try await restartStreamWithoutMicrophone()
                } else {
                    throw error
                }
            }
        } catch {
            await microphoneCapture?.stop()
            microphoneCapture = nil
            // The stream holds on to this object as its output.
            self.stream = nil
            queue.async {
                self.activeStreamID = nil
                self.writer.cancel()
            }
            throw error
        }
    }

    private func startFallbackMicrophoneCapture(for stream: SCStream) async {
        guard let device = microphoneDevice else { return }
        do {
            let capture = try MicrophoneCapture(
                device: device,
                sampleQueue: queue,
                targetClock: stream.synchronizationClock ?? CMClockGetHostTimeClock(),
                onSample: { [weak self] sampleBuffer, time in
                    self?.handleAudio(sampleBuffer, from: .microphone, at: time)
                }
            )
            try await capture.start()
            microphoneCapture = capture
        } catch {
            Log.capture.warning(
                "Microphone capture failed to start; continuing without microphone: \(error.localizedDescription, privacy: .public)"
            )
            audio.microphone = false
            queue.sync { self.writer.disableAudioSource(.microphone) }
        }
    }

    @available(macOS 15.0, *)
    private func restartStreamWithoutMicrophone() async throws {
        configuration.captureMicrophone = false
        audio.microphone = false
        let retryStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let retryStreamID = ObjectIdentifier(retryStream)
        self.stream = retryStream
        queue.sync {
            self.activeStreamID = retryStreamID
            self.writer.disableAudioSource(.microphone)
        }
        try retryStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if audio.systemAudio {
            try retryStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        try await retryStream.startCapture()
    }

    @available(macOS 15.0, *)
    static func isMicrophoneStartError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamErrorDomain
            && nsError.code == SCStreamError.Code.failedToStartMicrophoneCapture.rawValue
    }

    /// Ends the recording now, though `stop()` may come only later.
    func end() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        queue.async {
            if self.endTime == nil { self.endTime = now }
        }
    }

    /// Stops recording and finishes the file. Gives the recording's length,
    /// or nil when not a single frame came, in which case there is no file.
    func stop() async throws -> TimeInterval? {
        // Unless it already ended, the recording ends now, not once the
        // stream has stopped.
        end()
        try? await stream?.stopCapture()
        stream = nil
        await microphoneCapture?.stop()
        microphoneCapture = nil
        // Frames and audio buffers that arrived before the stop may still
        // wait on the queue. This runs after them.
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.activeStreamID = nil
                let end = self.endTime ?? CMClockGetTime(CMClockGetHostTimeClock())
                self.writer.finish(at: end) { continuation.resume(with: $0) }
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard ObjectIdentifier(stream) == activeStreamID else { return }
        if type == .screen {
            handleVideo(sampleBuffer)
        } else if type == .audio {
            handleAudio(sampleBuffer, from: .system)
        } else if #available(macOS 15.0, *), type == .microphone {
            handleAudio(sampleBuffer, from: .microphone)
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard
            !hasFailed,
            sampleBuffer.hasNewScreenFrame,
            let pixelBuffer = sampleBuffer.imageBuffer,
            CVPixelBufferGetWidth(pixelBuffer) == width,
            CVPixelBufferGetHeight(pixelBuffer) == height
        else { return }

        if let endTime, sampleBuffer.presentationTimeStamp > endTime { return }
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

    private func handleAudio(
        _ sampleBuffer: CMSampleBuffer,
        from source: AudioMixer.Source,
        at time: CMTime? = nil
    ) {
        guard !hasFailed else { return }
        let pts = time ?? sampleBuffer.presentationTimeStamp
        if let endTime, pts >= endTime { return }
        do {
            try writer.appendAudio(sampleBuffer, from: source, at: pts, upTo: endTime)
        } catch {
            hasFailed = true
            Log.capture.error("Recording audio could not be written: \(error.localizedDescription, privacy: .public)")
            onFailure(error)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let streamID = ObjectIdentifier(stream)
        queue.async {
            guard streamID == self.activeStreamID, !self.hasFailed else { return }
            self.hasFailed = true
            Log.capture.error("Recording stopped: \(error.localizedDescription, privacy: .public)")
            self.onFailure(error)
        }
    }
}
