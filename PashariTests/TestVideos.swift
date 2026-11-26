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

    /// Creates a Linear PCM `CMSampleBuffer` at `seconds` (on `TestVideos.time`
    /// clock unless `rawTime` is true) containing a sine wave or constant
    /// value. Supports Float32/Int16, mono/stereo, interleaved/non-interleaved,
    /// and arbitrary sample rates for testing format conversion and mixing.
    static func audioBuffer(
        sampleRate: Double = Double(RecordingWriter.audioSampleRate),
        channels: Int = 2,
        interleaved: Bool = true,
        isInt16: Bool = false,
        frames: Int = 960,
        at seconds: Double,
        rawTime: Bool = false,
        generator: (_ frame: Int, _ channel: Int) -> Float
    ) throws -> CMSampleBuffer {
        let bytesPerSample = isInt16 ? MemoryLayout<Int16>.size : MemoryLayout<Float>.size
        let formatFlags: AudioFormatFlags = isInt16
            ? (kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved))
            : (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved))
        let bytesPerFrame = UInt32(interleaved ? channels * bytesPerSample : bytesPerSample)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: formatFlags,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: UInt32(bytesPerSample * 8),
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        try #require(fmtStatus == noErr)
        let format = try #require(formatDescription)

        let totalSamples = frames * channels
        let byteCount = totalSamples * bytesPerSample
        var rawData = Data(count: byteCount)
        rawData.withUnsafeMutableBytes { rawBuffer in
            if isInt16 {
                let dst = rawBuffer.bindMemory(to: Int16.self)
                if interleaved {
                    for frame in 0..<frames {
                        for channel in 0..<channels {
                            let clamped = min(max(generator(frame, channel), -1), 1)
                            dst[frame * channels + channel] = Int16((clamped * Float(Int16.max)).rounded())
                        }
                    }
                } else {
                    for channel in 0..<channels {
                        for frame in 0..<frames {
                            let clamped = min(max(generator(frame, channel), -1), 1)
                            dst[channel * frames + frame] = Int16((clamped * Float(Int16.max)).rounded())
                        }
                    }
                }
            } else {
                let dst = rawBuffer.bindMemory(to: Float.self)
                if interleaved {
                    for frame in 0..<frames {
                        for channel in 0..<channels {
                            dst[frame * channels + channel] = generator(frame, channel)
                        }
                    }
                } else {
                    for channel in 0..<channels {
                        for frame in 0..<frames {
                            dst[channel * frames + frame] = generator(frame, channel)
                        }
                    }
                }
            }
        }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        try #require(blockStatus == kCMBlockBufferNoErr)
        let block = try #require(blockBuffer)
        let copyStatus = rawData.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        try #require(copyStatus == kCMBlockBufferNoErr)

        let pts = rawTime
            ? CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
            : time(seconds)
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: frames,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        try #require(sampleStatus == noErr)
        return try #require(sampleBuffer)
    }

    /// Reads the MP4's first audio track decoded into 48 kHz stereo Float32
    /// interleaved samples.
    static func decodedAudioSamples(in url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: RecordingWriter.audioSampleRate,
            AVNumberOfChannelsKey: RecordingWriter.audioChannelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        try #require(reader.startReading())
        var result: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            let frames = CMSampleBufferGetNumSamples(buffer)
            guard frames > 0, let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                  let pointer
            else { continue }
            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
                result.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
            }
        }
        return result
    }

    /// Root-mean-square level of a stereo interleaved sample slice on one channel.
    static func rms(of samples: [Float], channel: Int = 0, from startSecond: Double, to endSecond: Double) -> Float {
        let startFrame = max(0, Int((startSecond * Double(RecordingWriter.audioSampleRate)).rounded()))
        let endFrame = min(samples.count / 2, Int((endSecond * Double(RecordingWriter.audioSampleRate)).rounded()))
        guard endFrame > startFrame else { return 0 }
        var sumSquares: Double = 0
        for frame in startFrame..<endFrame {
            let sample = Double(samples[frame * 2 + channel])
            sumSquares += sample * sample
        }
        return Float(sqrt(sumSquares / Double(endFrame - startFrame)))
    }
}
