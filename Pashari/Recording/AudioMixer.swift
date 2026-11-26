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
///
/// Buffered PCM is stored as sorted non-overlapping segments so long silence
/// gaps never allocate sample arrays, and real-time recordings cap total
/// queued PCM memory if the encoder stalls.
nonisolated final class AudioMixer {
    enum Source: Hashable, Sendable {
        case system
        case microphone
    }

    static let sampleRate: Int = 48_000
    static let channelCount: Int = 2
    /// Maximum time one source waits for the other before flushing ahead
    /// (150 ms at 48 kHz), bounding latency and preventing stalls if one source
    /// goes quiet or stops delivering buffers.
    static let maximumLeadFrames: Int64 = 7_200
    /// Consecutive buffers from the same source whose input timestamps match
    /// the previous buffer's end within 2 ms are stitched seamlessly to absorb
    /// clock rounding and resampler priming delay without swallowing real
    /// dropped buffers (typically 10-20 ms).
    private static let contiguousInputToleranceSeconds: Double = 0.002
    /// Maximum cumulative snap distance (5 ms) when stitching contiguous
    /// buffers, preventing unbounded drift between device and host clocks.
    private static let maximumStitchOffsetFrames: Int64 = 240
    /// Maximum frames emitted per output sample buffer (~85 ms).
    private static let maximumChunkFrames: Int = 4_096
    /// Maximum real-time PCM buffered in memory while waiting on encoder
    /// backpressure (10 seconds ≈ 3.8 MiB).
    static let defaultMaximumBufferedFrames: Int = sampleRate * 10

    private static let canonicalFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(sampleRate),
        channels: AVAudioChannelCount(channelCount),
        interleaved: true
    )!

    private static let silenceChunk = [Float](repeating: 0, count: maximumChunkFrames * channelCount)

    private struct Segment {
        var startFrame: Int64
        var headFrame: Int = 0
        var samples: [Float]

        var frameCount: Int { (samples.count / AudioMixer.channelCount) - headFrame }
        var endFrame: Int64 { startFrame + Int64(frameCount) }
    }

    private var expectedSources: Set<Source>
    private let maximumDuration: CMTime
    private let maxFrames: Int64
    private let maximumBufferedFrames: Int?
    private let outputFormatDescription: CMAudioFormatDescription

    private var emittedFrames: Int64 = 0
    /// Sorted, non-overlapping PCM segments at or after `emittedFrames`.
    /// Any range between `emittedFrames` and a segment (or between two
    /// segments) is implicit silence and takes zero memory.
    private var segments: [Segment] = []
    private var latestFrameBySource: [Source: Int64] = [:]
    private var lastInputEndTimeBySource: [Source: CMTime] = [:]
    private var converters: [Source: SourceConverter] = [:]
    private(set) var hasReceivedAudio = false

    /// True while queued PCM or implicit silence is ready to be drained now.
    var hasPendingAudio: Bool {
        currentReadyTarget() > emittedFrames
    }

    /// Total frames currently stored in PCM segments (for memory bounding and tests).
    var bufferedFrames: Int {
        segments.reduce(0) { $0 + $1.frameCount }
    }

    init(
        sources: Set<Source>,
        maximumDuration: CMTime,
        maximumBufferedFrames: Int? = defaultMaximumBufferedFrames
    ) throws {
        self.expectedSources = sources
        self.maximumDuration = maximumDuration
        self.maxFrames = max(
            0,
            CMTimeConvertScale(maximumDuration, timescale: Int32(Self.sampleRate), method: .roundHalfAwayFromZero).value
        )
        self.maximumBufferedFrames = maximumBufferedFrames
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

    /// Stops expecting audio from `source`, e.g. when microphone capture fails
    /// to start and the recording continues with system audio only.
    func removeSource(_ source: Source) {
        expectedSources.remove(source)
        latestFrameBySource.removeValue(forKey: source)
        lastInputEndTimeBySource.removeValue(forKey: source)
        converters.removeValue(forKey: source)
    }

    /// Converts `sampleBuffer` to canonical 48 kHz stereo PCM, mixes it into
    /// the timeline relative to `startTime`, clips at `endTime` if given, and
    /// invokes `emit` for every ready output buffer. Returning `false` from
    /// `emit` pauses draining without discarding buffered samples so they can
    /// be emitted once the encoder becomes ready again.
    func append(
        _ sampleBuffer: CMSampleBuffer,
        from source: Source,
        at presentationTime: CMTime,
        startTime: CMTime,
        upTo endTime: CMTime? = nil,
        emit: (CMSampleBuffer) throws -> Bool
    ) throws {
        guard
            presentationTime.isNumeric,
            startTime.isNumeric,
            presentationTime.timescale > 0,
            startTime.timescale > 0
        else { return }
        let limitFrame = frameLimit(upTo: endTime, startTime: startTime)
        guard limitFrame > 0 else { return }

        let maxSeconds = Double(limitFrame) / Double(Self.sampleRate)
        let deltaSeconds = Self.exactSecondsDifference(presentationTime, startTime)
        // Guard against extreme out-of-range timestamps overflowing Int64 when
        // scaled to 48 kHz. Allow up to 1 s past `maxSeconds` here so
        // high-rate inputs that still have `remainingSeconds > 0` can be
        // resampled and stitched before the final `limitFrame` check.
        guard deltaSeconds.isFinite, deltaSeconds >= -600, deltaSeconds <= maxSeconds + 1 else { return }

        // Apply the earlier of explicit `endTime`, `maximumDuration`, and
        // `maxFrames` BEFORE copying or resampling input PCM so neither jitter
        // snapping nor resampler lookahead can leak samples past the stop
        // boundary. Computing the remaining duration directly from exact
        // whole-second and fractional-tick differences avoids both
        // `CMTimeAdd`/`CMTimeSubtract` LCM rounding and independent endpoint
        // rounding errors.
        var remainingSeconds = Self.remainingDurationSeconds(
            limit: CMTime(value: maxFrames, timescale: Int32(Self.sampleRate)),
            presentationTime: presentationTime,
            startTime: startTime
        )
        if maximumDuration.isNumeric, maximumDuration.timescale > 0 {
            remainingSeconds = min(
                remainingSeconds,
                Self.remainingDurationSeconds(
                    limit: maximumDuration,
                    presentationTime: presentationTime,
                    startTime: startTime
                )
            )
        }
        if let endTime, endTime.isNumeric, endTime.timescale > 0 {
            remainingSeconds = min(
                remainingSeconds,
                Self.exactSecondsDifference(endTime, presentationTime)
            )
        }
        guard remainingSeconds > 0 else { return }

        let converter = converter(for: source)
        guard let converted = converter.convert(
            sampleBuffer,
            maximumInputSeconds: remainingSeconds
        ) else {
            return
        }
        let samples = converted.samples
        let frameCount = samples.count / Self.channelCount
        guard frameCount > 0 else { return }
        if deltaSeconds + Double(frameCount) / Double(Self.sampleRate) <= 0 { return }

        let delta = CMTimeSubtract(presentationTime, startTime)
        guard delta.isNumeric else { return }
        var startFrame = CMTimeConvertScale(
            delta,
            timescale: Int32(Self.sampleRate),
            method: .roundHalfAwayFromZero
        ).value

        let inputEndTime = CMTimeAdd(presentationTime, converted.inputDuration)
        let previousInputEnd = lastInputEndTimeBySource[source]
        lastInputEndTimeBySource[source] = inputEndTime

        if
            let cursor = latestFrameBySource[source],
            let previousInputEnd,
            abs(CMTimeSubtract(presentationTime, previousInputEnd).seconds) <= Self.contiguousInputToleranceSeconds,
            abs(startFrame - cursor) <= Self.maximumStitchOffsetFrames
        {
            // Device/host clock rounding and FIR resampler priming can shift
            // consecutive buffers by a few samples. At ~50 ppm clock drift
            // this stays smooth and only corrects once drift exceeds 5 ms.
            startFrame = cursor
        }

        let rawEnd = startFrame + Int64(frameCount)
        if rawEnd <= emittedFrames {
            latestFrameBySource[source] = max(latestFrameBySource[source] ?? 0, min(rawEnd, limitFrame))
            return
        }
        guard startFrame < limitFrame else { return }

        let clippedStart = max(startFrame, emittedFrames)
        let clippedEnd = min(rawEnd, limitFrame)
        let skipFrames = Int(clippedStart - startFrame)
        let writeFrames = Int(clippedEnd - clippedStart)
        guard writeFrames > 0 else { return }

        latestFrameBySource[source] = max(latestFrameBySource[source] ?? 0, clippedEnd)
        hasReceivedAudio = true

        let readyFrame = min(limitFrame, currentReadyTarget())
        let preDrainTarget = min(clippedStart, readyFrame)
        if preDrainTarget > emittedFrames {
            _ = try drain(upTo: preDrainTarget, startTime: startTime, emit: emit)
        }

        mixIntoSegments(
            samples: samples,
            sourceFrameOffset: skipFrames,
            startFrame: clippedStart,
            frameCount: writeFrames
        )
        enforceBufferedFrameLimit()

        if readyFrame > emittedFrames {
            _ = try drain(upTo: readyFrame, startTime: startTime, emit: emit)
        }
    }

    /// Drains any queued audio that is already ready to emit, stopping if
    /// `emit` returns `false`.
    func drainReady(
        startTime: CMTime,
        upTo endTime: CMTime? = nil,
        emit: (CMSampleBuffer) throws -> Bool
    ) throws {
        guard hasReceivedAudio, startTime.isNumeric else { return }
        let limitFrame = frameLimit(upTo: endTime, startTime: startTime)
        let target = min(limitFrame, currentReadyTarget())
        if target > emittedFrames {
            _ = try drain(upTo: target, startTime: startTime, emit: emit)
        }
    }

    /// Flushes any remaining buffered audio up to `endTime`.
    func flush(
        upTo endTime: CMTime,
        startTime: CMTime,
        emit: (CMSampleBuffer) throws -> Bool
    ) throws {
        defer { segments.removeAll(keepingCapacity: false) }
        guard hasReceivedAudio, endTime.isNumeric, startTime.isNumeric else { return }
        let limitFrame = frameLimit(upTo: endTime, startTime: startTime)
        let highestWritten = latestFrameBySource.values.max() ?? 0
        let target = min(limitFrame, highestWritten)
        if target > emittedFrames {
            _ = try drain(upTo: target, startTime: startTime, emit: emit)
        }
    }

    func reset() {
        segments.removeAll(keepingCapacity: false)
        latestFrameBySource.removeAll()
        lastInputEndTimeBySource.removeAll()
        converters.removeAll()
        emittedFrames = 0
        hasReceivedAudio = false
    }

    private func frameLimit(upTo endTime: CMTime?, startTime: CMTime) -> Int64 {
        guard let endTime, endTime.isNumeric else { return maxFrames }
        let delta = CMTimeSubtract(endTime, startTime)
        guard delta.isNumeric else { return maxFrames }
        guard delta > .zero else { return 0 }
        let maxSeconds = Double(maxFrames) / Double(Self.sampleRate)
        if delta.seconds >= maxSeconds { return maxFrames }
        let endFrame = CMTimeConvertScale(
            delta,
            timescale: Int32(Self.sampleRate),
            method: .roundHalfAwayFromZero
        ).value
        return min(maxFrames, max(0, endFrame))
    }

    /// Computes `lhs - rhs` in seconds by splitting whole seconds from
    /// fractional ticks, avoiding both `CMTimeSubtract` LCM rounding (e.g.
    /// 48 kHz vs nanosecond host clock) and large-uptime `Double` cancellation.
    private static func exactSecondsDifference(_ lhs: CMTime, _ rhs: CMTime) -> Double {
        let lhsScale = Int64(lhs.timescale)
        let rhsScale = Int64(rhs.timescale)
        let wholeSeconds = Double(lhs.value / lhsScale) - Double(rhs.value / rhsScale)
        let remSeconds = Double(lhs.value % lhsScale) / Double(lhsScale)
            - Double(rhs.value % rhsScale) / Double(rhsScale)
        return wholeSeconds + remSeconds
    }

    /// Computes `limit - (presentationTime - startTime)` in seconds without
    /// `CMTimeAdd` rounding or large-uptime `Double` cancellation.
    private static func remainingDurationSeconds(
        limit: CMTime,
        presentationTime: CMTime,
        startTime: CMTime
    ) -> Double {
        let limitScale = Int64(limit.timescale)
        let presScale = Int64(presentationTime.timescale)
        let startScale = Int64(startTime.timescale)
        let limitWhole = Double(limit.value / limitScale)
        let limitRem = Double(limit.value % limitScale) / Double(limitScale)
        let deltaWhole = Double(presentationTime.value / presScale) - Double(startTime.value / startScale)
        let deltaRem = Double(presentationTime.value % presScale) / Double(presScale)
            - Double(startTime.value % startScale) / Double(startScale)
        return (limitWhole - deltaWhole) + (limitRem - deltaRem)
    }

    private func converter(for source: Source) -> SourceConverter {
        if let existing = converters[source] { return existing }
        let created = SourceConverter()
        converters[source] = created
        return created
    }

    private func currentReadyTarget() -> Int64 {
        guard hasReceivedAudio else { return 0 }
        if expectedSources.count <= 1 {
            return min(maxFrames, latestFrameBySource.values.max() ?? 0)
        }
        let latestValues = expectedSources.map { latestFrameBySource[$0] ?? 0 }
        let minLatest = latestValues.min() ?? 0
        let maxLatest = latestValues.max() ?? 0
        return min(maxFrames, max(minLatest, maxLatest - Self.maximumLeadFrames))
    }

    private func mixIntoSegments(
        samples: [Float],
        sourceFrameOffset: Int,
        startFrame: Int64,
        frameCount: Int
    ) {
        let endFrame = startFrame + Int64(frameCount)
        let srcFloatBase = sourceFrameOffset * Self.channelCount
        let floatCount = frameCount * Self.channelCount

        func sanitizedSlice() -> [Float] {
            var copy = [Float](repeating: 0, count: floatCount)
            for index in 0..<floatCount {
                let value = samples[srcFloatBase + index]
                copy[index] = value.isFinite ? value : 0
            }
            return copy
        }

        // Fast path: append directly to the last segment or add a disjoint tail segment.
        if let lastIndex = segments.indices.last {
            if startFrame == segments[lastIndex].endFrame {
                segments[lastIndex].samples.reserveCapacity(segments[lastIndex].samples.count + floatCount)
                for index in 0..<floatCount {
                    let value = samples[srcFloatBase + index]
                    segments[lastIndex].samples.append(value.isFinite ? value : 0)
                }
                return
            }
            if startFrame > segments[lastIndex].endFrame {
                segments.append(Segment(startFrame: startFrame, samples: sanitizedSlice()))
                return
            }
        } else {
            segments.append(Segment(startFrame: startFrame, samples: sanitizedSlice()))
            return
        }

        // General path: insert into a silence gap or coalesce overlapping/adjacent segments.
        let firstOverlap = segments.firstIndex { $0.endFrame >= startFrame } ?? segments.count
        var afterOverlap = firstOverlap
        while afterOverlap < segments.count, segments[afterOverlap].startFrame <= endFrame {
            afterOverlap += 1
        }
        if firstOverlap == afterOverlap {
            segments.insert(Segment(startFrame: startFrame, samples: sanitizedSlice()), at: firstOverlap)
            return
        }

        let mergedStart = min(startFrame, segments[firstOverlap].startFrame)
        let mergedEnd = max(endFrame, segments[afterOverlap - 1].endFrame)
        let mergedFloats = Int(mergedEnd - mergedStart) * Self.channelCount
        var merged = [Float](repeating: 0, count: mergedFloats)

        for segIndex in firstOverlap..<afterOverlap {
            let segment = segments[segIndex]
            let dstBase = Int(segment.startFrame - mergedStart) * Self.channelCount
            let srcBase = segment.headFrame * Self.channelCount
            let segFloats = segment.frameCount * Self.channelCount
            for offset in 0..<segFloats {
                merged[dstBase + offset] += segment.samples[srcBase + offset]
            }
        }
        let incomingDstBase = Int(startFrame - mergedStart) * Self.channelCount
        for offset in 0..<floatCount {
            let value = samples[srcFloatBase + offset]
            if value.isFinite {
                merged[incomingDstBase + offset] += value
            }
        }
        segments.replaceSubrange(
            firstOverlap..<afterOverlap,
            with: [Segment(startFrame: mergedStart, samples: merged)]
        )
    }

    private func enforceBufferedFrameLimit() {
        guard let limit = maximumBufferedFrames else { return }
        var total = bufferedFrames
        while total > limit, !segments.isEmpty {
            let excess = total - limit
            if segments[0].frameCount <= excess {
                total -= segments[0].frameCount
                segments.removeFirst()
            } else {
                segments[0].headFrame += excess
                segments[0].startFrame += Int64(excess)
                if segments[0].headFrame >= Self.maximumChunkFrames {
                    segments[0].samples.removeFirst(segments[0].headFrame * Self.channelCount)
                    segments[0].headFrame = 0
                }
                total -= excess
            }
        }
    }

    private func drain(
        upTo targetFrame: Int64,
        startTime: CMTime,
        emit: (CMSampleBuffer) throws -> Bool
    ) throws -> Bool {
        while emittedFrames < targetFrame {
            if segments.isEmpty || emittedFrames < segments[0].startFrame {
                let silenceEnd = segments.isEmpty
                    ? targetFrame
                    : min(targetFrame, segments[0].startFrame)
                let chunkFrames = Int(min(silenceEnd - emittedFrames, Int64(Self.maximumChunkFrames)))
                let sampleBuffer = try makeSampleBuffer(
                    from: Self.silenceChunk,
                    frameCount: chunkFrames,
                    atFrame: emittedFrames,
                    startTime: startTime
                )
                guard try emit(sampleBuffer) else { return false }
                emittedFrames += Int64(chunkFrames)
            } else {
                let availEnd = min(targetFrame, segments[0].endFrame)
                let chunkFrames = Int(min(availEnd - emittedFrames, Int64(Self.maximumChunkFrames)))
                let floatStart = segments[0].headFrame * Self.channelCount
                let floatCount = chunkFrames * Self.channelCount
                var chunk = [Float](repeating: 0, count: floatCount)
                for index in 0..<floatCount {
                    let sample = segments[0].samples[floatStart + index]
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
                if chunkFrames >= segments[0].frameCount {
                    segments.removeFirst()
                } else {
                    segments[0].headFrame += chunkFrames
                    segments[0].startFrame += Int64(chunkFrames)
                    if segments[0].headFrame >= Self.maximumChunkFrames {
                        segments[0].samples.removeFirst(segments[0].headFrame * Self.channelCount)
                        segments[0].headFrame = 0
                    }
                }
            }
        }
        return true
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

        func convert(
            _ sampleBuffer: CMSampleBuffer,
            maximumInputSeconds: Double
        ) -> (samples: [Float], inputDuration: CMTime)? {
            guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else {
                return nil
            }
            let rawFrameCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard
                rawFrameCount > 0,
                let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
                CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_Audio
            else { return nil }
            let inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
            guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else { return nil }

            let inputRate = CMTimeScale(inputFormat.sampleRate.rounded())
            let allowed = floor(maximumInputSeconds * inputFormat.sampleRate + 1e-9)
            guard allowed >= 1 else { return nil }
            let frameCount = allowed >= Double(rawFrameCount) ? rawFrameCount : Int(allowed)

            guard let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
            ) else { return nil }

            pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
            let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer,
                at: 0,
                frameCount: Int32(frameCount),
                into: pcmBuffer.mutableAudioBufferList
            )
            guard copyStatus == noErr else { return nil }

            let inputDuration = CMTime(value: Int64(frameCount), timescale: inputRate)
            if inputFormat.sampleRate == Double(AudioMixer.sampleRate),
               inputFormat.commonFormat == .pcmFormatFloat32,
               let direct = fastConvertFloat32AtCanonicalRate(pcmBuffer, format: inputFormat)
            {
                return (direct, inputDuration)
            }

            guard let converted = convertWithAudioConverter(pcmBuffer, inputFormat: inputFormat) else {
                return nil
            }
            return (converted, inputDuration)
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
