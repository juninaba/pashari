import AVFoundation
import CoreMedia

/// Mixes and normalizes incoming PCM audio buffers from one or two sources
/// (system audio and microphone) into a single continuous 48 kHz stereo
/// Float32 interleaved timeline aligned to a recording's start time.
///
/// Producing one continuous PCM stream keeps browser, Slack and QuickTime
/// playback reliable: there are no edit-list offsets, no overlapping sample
/// timestamps, and only one AAC track even when system audio and microphone
/// are both recorded.
nonisolated final class AudioMixer {
    enum Source: Hashable, Sendable {
        case system
        case microphone
    }

    static let sampleRate: Int = 48_000
    static let channelCount: Int = 2
    /// Maximum time one source waits for the other before flushing ahead
    /// (150 ms at 48 kHz), bounding memory and preventing stalls if one source
    /// goes quiet or stops delivering buffers.
    static let maximumLeadFrames: Int64 = 7_200
    /// Small clock jitter between consecutive buffers of the same source
    /// (up to 10 ms) is absorbed to avoid clicks and single-sample gaps.
    private static let jitterToleranceFrames: Int64 = 480
    /// Maximum frames emitted per output sample buffer (~85 ms).
    private static let maximumChunkFrames: Int = 4_096

    private static let canonicalFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(sampleRate),
        channels: AVAudioChannelCount(channelCount),
        interleaved: true
    )!

    private static let silenceChunk = [Float](repeating: 0, count: maximumChunkFrames * channelCount)

    private let expectedSources: Set<Source>
    private let maxFrames: Int64
    private let outputFormatDescription: CMAudioFormatDescription

    private var emittedFrames: Int64 = 0
    /// Timeline frame corresponding to `mixBuffer[mixHead * channelCount]`.
    /// Always `>= emittedFrames`; frames in `[emittedFrames, bufferStartFrame)`
    /// represent implicit silence without allocating memory.
    private var bufferStartFrame: Int64 = 0
    /// Interleaved stereo floats starting at `bufferStartFrame - mixHead`.
    private var mixBuffer: [Float] = []
    /// Frame offset of `bufferStartFrame` within `mixBuffer`.
    private var mixHead: Int = 0
    private var latestFrameBySource: [Source: Int64] = [:]
    private var converters: [Source: SourceConverter] = [:]
    private(set) var hasReceivedAudio = false

    private var bufferedFrameCount: Int {
        (mixBuffer.count / Self.channelCount) - mixHead
    }

    init(sources: Set<Source>, maximumDuration: CMTime) throws {
        self.expectedSources = sources
        self.maxFrames = max(
            0,
            CMTimeConvertScale(maximumDuration, timescale: Int32(Self.sampleRate), method: .roundHalfAwayFromZero).value
        )
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(Self.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(Self.channelCount * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(Self.channelCount * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(Self.channelCount),
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.outputFormatDescription = formatDescription
    }

    /// Converts `sampleBuffer` to canonical 48 kHz stereo PCM, mixes it into
    /// the timeline relative to `startTime`, and invokes `emit` for every
    /// ready output buffer. Returning `false` from `emit` pauses draining
    /// without discarding buffered samples so they can be emitted once the
    /// encoder becomes ready again.
    func append(
        _ sampleBuffer: CMSampleBuffer,
        from source: Source,
        at presentationTime: CMTime,
        startTime: CMTime,
        emit: (CMSampleBuffer) throws -> Bool
    ) throws {
        guard presentationTime.isNumeric, startTime.isNumeric else { return }
        let converter = converter(for: source)
        guard let samples = converter.convert(sampleBuffer) else { return }
        let frameCount = samples.count / Self.channelCount
        guard frameCount > 0 else { return }

        let delta = CMTimeSubtract(presentationTime, startTime)
        guard delta.isNumeric else { return }
        let maxSeconds = Double(maxFrames) / Double(Self.sampleRate)
        if delta.seconds >= maxSeconds + 10 { return }
        if delta.seconds + Double(frameCount) / Double(Self.sampleRate) <= 0 { return }

        var startFrame = CMTimeConvertScale(
            delta,
            timescale: Int32(Self.sampleRate),
            method: .roundHalfAwayFromZero
        ).value
        if let cursor = latestFrameBySource[source], abs(startFrame - cursor) <= Self.jitterToleranceFrames {
            startFrame = cursor
        }

        let rawEnd = startFrame + Int64(frameCount)
        if rawEnd <= emittedFrames {
            latestFrameBySource[source] = max(latestFrameBySource[source] ?? 0, min(rawEnd, maxFrames))
            return
        }
        guard startFrame < maxFrames else { return }

        let clippedStart = max(startFrame, emittedFrames)
        let clippedEnd = min(rawEnd, maxFrames)
        let skipFrames = Int(clippedStart - startFrame)
        let writeFrames = Int(clippedEnd - clippedStart)
        guard writeFrames > 0 else { return }

        latestFrameBySource[source] = max(latestFrameBySource[source] ?? 0, clippedEnd)
        hasReceivedAudio = true

        let readyFrame = readyTarget(afterUpdating: source, to: clippedEnd)
        let preDrainTarget = min(clippedStart, readyFrame)
        if preDrainTarget > emittedFrames {
            _ = try drain(upTo: preDrainTarget, startTime: startTime, emit: emit)
        }

        if bufferedFrameCount == 0 {
            bufferStartFrame = clippedStart
            mixHead = 0
            mixBuffer.removeAll(keepingCapacity: true)
        } else if clippedStart < bufferStartFrame {
            let prependFrames = Int(bufferStartFrame - clippedStart)
            if mixHead >= prependFrames {
                let startFloat = (mixHead - prependFrames) * Self.channelCount
                let endFloat = mixHead * Self.channelCount
                for index in startFloat..<endFloat {
                    mixBuffer[index] = 0
                }
                mixHead -= prependFrames
            } else {
                if mixHead > 0 {
                    mixBuffer.removeFirst(mixHead * Self.channelCount)
                    mixHead = 0
                }
                mixBuffer.insert(
                    contentsOf: repeatElement(Float(0), count: prependFrames * Self.channelCount),
                    at: 0
                )
            }
            bufferStartFrame = clippedStart
        }

        let relativeStart = Int(clippedStart - bufferStartFrame)
        let relativeEnd = relativeStart + writeFrames
        let requiredFloats = (mixHead + relativeEnd) * Self.channelCount
        if mixBuffer.count < requiredFloats {
            mixBuffer.append(contentsOf: repeatElement(Float(0), count: requiredFloats - mixBuffer.count))
        }
        let dstBase = (mixHead + relativeStart) * Self.channelCount
        let srcBase = skipFrames * Self.channelCount
        let floatCount = writeFrames * Self.channelCount
        for index in 0..<floatCount {
            let value = samples[srcBase + index]
            if value.isFinite {
                mixBuffer[dstBase + index] += value
            }
        }

        if readyFrame > emittedFrames {
            _ = try drain(upTo: readyFrame, startTime: startTime, emit: emit)
        }
    }

    /// Flushes any remaining buffered audio up to `endTime`.
    func flush(
        upTo endTime: CMTime,
        startTime: CMTime,
        emit: (CMSampleBuffer) throws -> Bool
    ) throws {
        defer { resetBuffer() }
        guard hasReceivedAudio, endTime.isNumeric, startTime.isNumeric else { return }
        let delta = CMTimeSubtract(endTime, startTime)
        guard delta.isNumeric, delta > .zero else { return }
        let endFrame = min(
            maxFrames,
            CMTimeConvertScale(delta, timescale: Int32(Self.sampleRate), method: .roundHalfAwayFromZero).value
        )
        let highestWritten = latestFrameBySource.values.max() ?? 0
        let target = min(endFrame, highestWritten)
        if target > emittedFrames {
            _ = try drain(upTo: target, startTime: startTime, emit: emit)
        }
    }

    func reset() {
        resetBuffer()
        latestFrameBySource.removeAll()
        converters.removeAll()
        emittedFrames = 0
        bufferStartFrame = 0
        hasReceivedAudio = false
    }

    private func resetBuffer() {
        mixBuffer.removeAll(keepingCapacity: false)
        mixHead = 0
        bufferStartFrame = emittedFrames
    }

    private func converter(for source: Source) -> SourceConverter {
        if let existing = converters[source] { return existing }
        let created = SourceConverter()
        converters[source] = created
        return created
    }

    private func readyTarget(afterUpdating source: Source, to latestEnd: Int64) -> Int64 {
        guard expectedSources.count > 1 else {
            return latestEnd
        }
        let sourceLatest = latestFrameBySource[source] ?? latestEnd
        let otherLatest = expectedSources
            .filter { $0 != source }
            .map { latestFrameBySource[$0] ?? 0 }
            .min() ?? 0
        let minLatest = min(sourceLatest, otherLatest)
        let maxLatest = max(sourceLatest, otherLatest)
        return min(maxFrames, max(minLatest, maxLatest - Self.maximumLeadFrames))
    }

    private func drain(
        upTo targetFrame: Int64,
        startTime: CMTime,
        emit: (CMSampleBuffer) throws -> Bool
    ) throws -> Bool {
        // 1. Implicit silence before `bufferStartFrame`.
        let silenceEnd = min(targetFrame, bufferStartFrame)
        while emittedFrames < silenceEnd {
            let chunkFrames = Int(min(silenceEnd - emittedFrames, Int64(Self.maximumChunkFrames)))
            let sampleBuffer = try makeSampleBuffer(
                from: Self.silenceChunk,
                frameCount: chunkFrames,
                atFrame: emittedFrames,
                startTime: startTime
            )
            guard try emit(sampleBuffer) else { return false }
            emittedFrames += Int64(chunkFrames)
        }

        // 2. Buffered PCM samples starting at `bufferStartFrame`.
        while emittedFrames < targetFrame, bufferedFrameCount > 0 {
            let chunkFrames = Int(min(
                targetFrame - emittedFrames,
                Int64(bufferedFrameCount),
                Int64(Self.maximumChunkFrames)
            ))
            let floatStart = mixHead * Self.channelCount
            let floatCount = chunkFrames * Self.channelCount
            var chunk = [Float](repeating: 0, count: floatCount)
            for index in 0..<floatCount {
                let sample = mixBuffer[floatStart + index]
                chunk[index] = min(max(sample, -1), 1)
            }
            let sampleBuffer = try makeSampleBuffer(
                from: chunk,
                frameCount: chunkFrames,
                atFrame: emittedFrames,
                startTime: startTime
            )
            guard try emit(sampleBuffer) else { return false }
            emittedFrames += Int64(chunkFrames)
            bufferStartFrame += Int64(chunkFrames)
            mixHead += chunkFrames
            compactBufferIfNeeded()
        }

        // 3. Any remaining silence past the end of `mixBuffer` up to `targetFrame`.
        while emittedFrames < targetFrame {
            let chunkFrames = Int(min(targetFrame - emittedFrames, Int64(Self.maximumChunkFrames)))
            let sampleBuffer = try makeSampleBuffer(
                from: Self.silenceChunk,
                frameCount: chunkFrames,
                atFrame: emittedFrames,
                startTime: startTime
            )
            guard try emit(sampleBuffer) else { return false }
            emittedFrames += Int64(chunkFrames)
            bufferStartFrame = emittedFrames
        }
        return true
    }

    private func compactBufferIfNeeded() {
        let headFloats = mixHead * Self.channelCount
        if headFloats >= mixBuffer.count {
            mixBuffer.removeAll(keepingCapacity: true)
            mixHead = 0
            bufferStartFrame = emittedFrames
        } else if mixHead >= Self.maximumChunkFrames {
            mixBuffer.removeFirst(headFloats)
            mixHead = 0
        }
    }

    private func makeSampleBuffer(
        from samples: [Float],
        frameCount: Int,
        atFrame frameIndex: Int64,
        startTime: CMTime
    ) throws -> CMSampleBuffer {
        let byteCount = frameCount * Self.channelCount * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        let createBlockStatus = CMBlockBufferCreateWithMemoryBlock(
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
        guard createBlockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw CocoaError(.fileWriteUnknown)
        }
        let copyStatus = samples.withUnsafeBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw CocoaError(.fileWriteUnknown)
        }

        let offset = CMTime(value: frameIndex, timescale: Int32(Self.sampleRate))
        let pts = CMTimeAdd(startTime, offset)
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: outputFormatDescription,
            sampleCount: frameCount,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw CocoaError(.fileWriteUnknown)
        }
        return sampleBuffer
    }

    /// Converts buffers from a single audio source into 48 kHz stereo Float32
    /// interleaved samples, keeping its `AVAudioConverter` alive across
    /// buffers so resampling remains click-free.
    private final class SourceConverter {
        private var cachedFormat: AVAudioFormat?
        private var converter: AVAudioConverter?

        func convert(_ sampleBuffer: CMSampleBuffer) -> [Float]? {
            guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else {
                return nil
            }
            let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard
                frameCount > 0,
                let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
                CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_Audio
            else { return nil }
            let inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
            guard
                inputFormat.channelCount > 0,
                inputFormat.sampleRate > 0,
                let pcmBuffer = AVAudioPCMBuffer(
                    pcmFormat: inputFormat,
                    frameCapacity: AVAudioFrameCount(frameCount)
                )
            else { return nil }

            pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
            let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer,
                at: 0,
                frameCount: Int32(frameCount),
                into: pcmBuffer.mutableAudioBufferList
            )
            guard copyStatus == noErr else { return nil }

            if inputFormat.sampleRate == Double(AudioMixer.sampleRate),
               inputFormat.commonFormat == .pcmFormatFloat32
            {
                if let direct = fastConvertFloat32AtCanonicalRate(pcmBuffer, format: inputFormat) {
                    return direct
                }
            }

            return convertWithAudioConverter(pcmBuffer, inputFormat: inputFormat)
        }

        private func fastConvertFloat32AtCanonicalRate(
            _ pcmBuffer: AVAudioPCMBuffer,
            format: AVAudioFormat
        ) -> [Float]? {
            let frames = Int(pcmBuffer.frameLength)
            if format.isInterleaved {
                let buffer = pcmBuffer.audioBufferList.pointee.mBuffers
                guard let raw = buffer.mData else { return nil }
                let pointer = raw.assumingMemoryBound(to: Float.self)
                if format.channelCount == 2 {
                    return Array(UnsafeBufferPointer(start: pointer, count: frames * 2))
                }
                if format.channelCount == 1 {
                    var output = [Float](repeating: 0, count: frames * 2)
                    for index in 0..<frames {
                        let sample = pointer[index]
                        output[index * 2] = sample
                        output[index * 2 + 1] = sample
                    }
                    return output
                }
                return nil
            }

            guard let channelData = pcmBuffer.floatChannelData else { return nil }
            if format.channelCount == 2 {
                let left = channelData[0]
                let right = channelData[1]
                var output = [Float](repeating: 0, count: frames * 2)
                for index in 0..<frames {
                    output[index * 2] = left[index]
                    output[index * 2 + 1] = right[index]
                }
                return output
            }
            if format.channelCount == 1 {
                let mono = channelData[0]
                var output = [Float](repeating: 0, count: frames * 2)
                for index in 0..<frames {
                    let sample = mono[index]
                    output[index * 2] = sample
                    output[index * 2 + 1] = sample
                }
                return output
            }
            return nil
        }

        private func convertWithAudioConverter(
            _ pcmBuffer: AVAudioPCMBuffer,
            inputFormat: AVAudioFormat
        ) -> [Float]? {
            if converter == nil || cachedFormat != inputFormat {
                guard let newConverter = AVAudioConverter(from: inputFormat, to: AudioMixer.canonicalFormat) else {
                    return nil
                }
                if inputFormat.channelCount == 1 {
                    // Center mono microphones across both stereo channels.
                    newConverter.channelMap = [0, 0]
                } else if inputFormat.channelCount > 2, inputFormat.channelLayout == nil {
                    newConverter.channelMap = [0, 1]
                }
                converter = newConverter
                cachedFormat = inputFormat
            }
            guard let converter else { return nil }

            let ratio = Double(AudioMixer.sampleRate) / max(inputFormat.sampleRate, 1)
            let capacity = max(1, AVAudioFrameCount(ceil(Double(pcmBuffer.frameLength) * ratio)) + 64)
            guard let outBuffer = AVAudioPCMBuffer(
                pcmFormat: AudioMixer.canonicalFormat,
                frameCapacity: capacity
            ) else { return nil }

            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return pcmBuffer
            }
            guard status != .error, conversionError == nil, outBuffer.frameLength > 0 else {
                return nil
            }
            let rawBuffer = outBuffer.audioBufferList.pointee.mBuffers
            guard let data = rawBuffer.mData else { return nil }
            let count = Int(outBuffer.frameLength) * AudioMixer.channelCount
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        }
    }
}
