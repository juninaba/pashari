import AVFoundation
import CoreMedia

/// Captures microphone audio through AVFoundation on macOS 14, where
/// ScreenCaptureKit does not yet capture microphone input.
///
/// Sample buffers arrive on `sampleQueue`, with timestamps converted onto
/// `targetClock` (the host time clock shared with `SCStream`) so the
/// microphone stays synchronized with the screen video and system audio.
nonisolated final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let controlQueue = DispatchQueue(label: "io.github.juninaba.pashari.microphone-control")
    private let targetClock: CMClock
    private let onSample: @Sendable (CMSampleBuffer, CMTime) -> Void

    init(
        device: AVCaptureDevice,
        sampleQueue: DispatchQueue,
        targetClock: CMClock = CMClockGetHostTimeClock(),
        onSample: @escaping @Sendable (CMSampleBuffer, CMTime) -> Void
    ) throws {
        self.targetClock = targetClock
        self.onSample = onSample
        super.init()

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: sampleQueue)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw CocoaError(.featureUnsupported)
        }
        session.addInput(input)
        session.addOutput(output)
    }

    func start() async throws {
        let running = await withCheckedContinuation { continuation in
            controlQueue.async {
                self.session.startRunning()
                continuation.resume(returning: self.session.isRunning)
            }
        }
        guard running else {
            throw CocoaError(.featureUnsupported)
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            controlQueue.async {
                self.session.stopRunning()
                continuation.resume()
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let time = Self.convertTimestamp(
            sampleBuffer.presentationTimeStamp,
            from: session.synchronizationClock,
            to: targetClock
        )
        onSample(sampleBuffer, time)
    }

    static func convertTimestamp(
        _ time: CMTime,
        from sourceClock: CMClock?,
        to targetClock: CMClock
    ) -> CMTime {
        guard let sourceClock else { return time }
        return CMSyncConvertTime(time, from: sourceClock, to: targetClock)
    }
}
