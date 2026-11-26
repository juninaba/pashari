import AVFoundation
import CoreMedia
import Testing

@testable import Pashari

struct AudioMixerTests {
    @Test func singleSourceEmitsStereoSamplesAlignedToStartTime() throws {
        let mixer = try AudioMixer(sources: [.system], maximumDuration: CMTime(value: 10, timescale: 1))
        let start = TestVideos.time(0)
        var emitted: [CMSampleBuffer] = []

        // First buffer straddles startTime (-0.01 s .. +0.01 s): only the second half should emit.
        let straddling = try TestVideos.audioBuffer(frames: 960, at: -0.01) { _, channel in
            channel == 0 ? 0.25 : -0.5
        }
        try mixer.append(straddling, from: .system, at: straddling.presentationTimeStamp, startTime: start) {
            emitted.append($0)
            return true
        }
        try mixer.flush(upTo: TestVideos.time(1), startTime: start) { emitted.append($0); return true }

        let samples = extractFloats(from: emitted)
        #expect(samples.count == 480 * 2)
        #expect(emitted.first?.presentationTimeStamp == start)
        #expect(abs(samples[0] - 0.25) < 0.001)
        #expect(abs(samples[1] - (-0.5)) < 0.001)
    }

    @Test func dualSourcesMixIntoOneStereoStreamAndClampPeaks() throws {
        let mixer = try AudioMixer(sources: [.system, .microphone], maximumDuration: CMTime(value: 10, timescale: 1))
        let start = TestVideos.time(0)
        var emitted: [CMSampleBuffer] = []

        // System audio sends 960 frames (20 ms) at +0.6 L / +0.7 R.
        let system = try TestVideos.audioBuffer(frames: 960, at: 0) { _, channel in
            channel == 0 ? 0.6 : 0.7
        }
        // Mic sends mono 480 frames (10 ms) at +0.25, then 480 frames at +0.6 (causes clipping > 1.0).
        let mic1 = try TestVideos.audioBuffer(channels: 1, interleaved: false, frames: 480, at: 0) { _, _ in 0.25 }
        let mic2 = try TestVideos.audioBuffer(channels: 1, interleaved: false, frames: 480, at: 0.01) { _, _ in 0.6 }

        try mixer.append(system, from: .system, at: system.presentationTimeStamp, startTime: start) { emitted.append($0); return true }
        // Still waiting for microphone within the lead window.
        #expect(emitted.isEmpty)

        try mixer.append(mic1, from: .microphone, at: mic1.presentationTimeStamp, startTime: start) { emitted.append($0); return true }
        try mixer.append(mic2, from: .microphone, at: mic2.presentationTimeStamp, startTime: start) { emitted.append($0); return true }
        try mixer.flush(upTo: TestVideos.time(0.02), startTime: start) { emitted.append($0); return true }

        let samples = extractFloats(from: emitted)
        #expect(samples.count == 960 * 2)
        // First 10 ms: 0.6 + 0.25 = 0.85 L, 0.7 + 0.25 = 0.95 R.
        #expect(abs(samples[0] - 0.85) < 0.001)
        #expect(abs(samples[1] - 0.95) < 0.001)
        // Second 10 ms: 0.6 + 0.6 = 1.2 -> clamped to 1.0 on both channels.
        #expect(abs(samples[480 * 2] - 1.0) < 0.001)
        #expect(abs(samples[480 * 2 + 1] - 1.0) < 0.001)
    }

    @Test func oneActiveSourceFlushesAheadWhenTheOtherIsSilent() throws {
        let mixer = try AudioMixer(sources: [.system, .microphone], maximumDuration: CMTime(value: 10, timescale: 1))
        let start = TestVideos.time(0)
        var emitted: [CMSampleBuffer] = []

        // Send 300 ms of microphone audio with zero system audio.
        for chunk in 0..<15 {
            let buffer = try TestVideos.audioBuffer(channels: 1, frames: 960, at: Double(chunk) * 0.02) { _, _ in 0.3 }
            try mixer.append(buffer, from: .microphone, at: buffer.presentationTimeStamp, startTime: start) {
                emitted.append($0)
                return true
            }
        }
        // Beyond the 150 ms lead window, chunks should already have started streaming out.
        let streamedFrames = extractFloats(from: emitted).count / 2
        #expect(streamedFrames >= 7_200)

        try mixer.flush(upTo: TestVideos.time(0.3), startTime: start) { emitted.append($0); return true }
        let totalFrames = extractFloats(from: emitted).count / 2
        #expect(totalFrames == 14_400)
    }

    @Test func lowSampleRateInt16MonoMicConvertsToCentered48kHzStereo() throws {
        let mixer = try AudioMixer(sources: [.microphone], maximumDuration: CMTime(value: 10, timescale: 1))
        let start = TestVideos.time(0)
        var emitted: [CMSampleBuffer] = []

        // 16 kHz mono Int16 (like Bluetooth HFP headsets), 100 ms in 20 ms chunks.
        for chunk in 0..<5 {
            let buffer = try TestVideos.audioBuffer(
                sampleRate: 16_000,
                channels: 1,
                interleaved: true,
                isInt16: true,
                frames: 320,
                at: Double(chunk) * 0.02
            ) { _, _ in 0.5 }
            try mixer.append(buffer, from: .microphone, at: buffer.presentationTimeStamp, startTime: start) {
                emitted.append($0)
                return true
            }
        }
        try mixer.flush(upTo: TestVideos.time(0.1), startTime: start) { emitted.append($0); return true }

        let samples = extractFloats(from: emitted)
        let frames = samples.count / 2
        // 100 ms at 48 kHz is ~4800 frames (resampler filter delay leaves a few dozen frames at the tail).
        #expect(frames > 4_400 && frames <= 4_800)
        // Middle of the buffer should be steady ~0.5 on both Left and Right channels.
        let mid = frames / 2
        #expect(abs(samples[mid * 2] - 0.5) < 0.05)
        #expect(abs(samples[mid * 2 + 1] - 0.5) < 0.05)
    }

    @Test func smallJitterStitchesWithoutGapsAndLargeGapsFillWithSilence() throws {
        let mixer = try AudioMixer(sources: [.system], maximumDuration: CMTime(value: 10, timescale: 1))
        let start = TestVideos.time(0)
        var emitted: [CMSampleBuffer] = []

        let first = try TestVideos.audioBuffer(frames: 960, at: 0) { _, _ in 0.4 }
        // +1 ms jitter (within 2 ms contiguous tolerance) should stitch at frame 960 without inserting silence.
        let jittered = try TestVideos.audioBuffer(frames: 960, at: 0.021) { _, _ in 0.4 }
        // Jump to 0.1 s (59 ms gap) should zero-fill frames [1920 ..< 4800).
        let afterGap = try TestVideos.audioBuffer(frames: 480, at: 0.1) { _, _ in 0.4 }

        for buffer in [first, jittered, afterGap] {
            try mixer.append(buffer, from: .system, at: buffer.presentationTimeStamp, startTime: start) {
                emitted.append($0)
                return true
            }
        }

        let samples = extractFloats(from: emitted)
        #expect(samples.count == 5_280 * 2)
        // Frame 960 has no silence gap.
        #expect(abs(samples[960 * 2] - 0.4) < 0.001)
        // Frame 2500 is inside the silence gap.
        #expect(samples[2_500 * 2] == 0)
        // Frame 4800 resumes at 0.4.
        #expect(abs(samples[4_800 * 2] - 0.4) < 0.001)
    }

    @Test func aDroppedTenMillisecondBufferIsPreservedAsSilenceWithoutShiftingLaterAudio() throws {
        let mixer = try AudioMixer(sources: [.system], maximumDuration: CMTime(value: 10, timescale: 1))
        let start = TestVideos.time(0)
        var emitted: [CMSampleBuffer] = []

        // 10 ms buffers at 0.00 s, (0.01 s dropped!), 0.02 s, 0.03 s.
        let b0 = try TestVideos.audioBuffer(frames: 480, at: 0.00) { _, _ in 0.25 }
        let b2 = try TestVideos.audioBuffer(frames: 480, at: 0.02) { _, _ in 0.5 }
        let b3 = try TestVideos.audioBuffer(frames: 480, at: 0.03) { _, _ in 0.75 }
        for buffer in [b0, b2, b3] {
            try mixer.append(buffer, from: .system, at: buffer.presentationTimeStamp, startTime: start) {
                emitted.append($0)
                return true
            }
        }

        let samples = extractFloats(from: emitted)
        #expect(samples.count == 1_920 * 2)
        // [0..480) = 0.25, [480..960) = 0 (dropped buffer), [960..1440) = 0.5, [1440..1920) = 0.75.
        #expect(abs(samples[0] - 0.25) < 0.001)
        #expect(samples[480 * 2] == 0)
        #expect(samples[959 * 2] == 0)
        #expect(abs(samples[960 * 2] - 0.5) < 0.001)
        #expect(abs(samples[1_440 * 2] - 0.75) < 0.001)
    }

    @Test func audioStraddlingEndTimeIsTruncatedSampleAccurately() throws {
        let mixer = try AudioMixer(sources: [.system], maximumDuration: CMTime(value: 10, timescale: 1))
        let start = TestVideos.time(0)
        let stopAt = TestVideos.time(0.01)
        var emitted: [CMSampleBuffer] = []

        // 20 ms buffer: first 10 ms at 0.25, second 10 ms (past stopAt) at 0.9.
        let straddling = try TestVideos.audioBuffer(frames: 960, at: 0) { frame, _ in
            frame < 480 ? 0.25 : 0.9
        }
        try mixer.append(straddling, from: .system, at: straddling.presentationTimeStamp, startTime: start, upTo: stopAt) {
            emitted.append($0)
            return true
        }
        try mixer.flush(upTo: stopAt, startTime: start) { emitted.append($0); return true }

        let samples = extractFloats(from: emitted)
        #expect(samples.count == 480 * 2)
        #expect(samples.allSatisfy { abs($0 - 0.25) < 0.001 })
    }

    @Test func disjointBuffersUnderBackpressureDoNotAllocateSilenceAndRespectBufferLimit() throws {
        let mixer = try AudioMixer(
            sources: [.system],
            maximumDuration: CMTime(value: 300, timescale: 1),
            maximumBufferedFrames: 1_440
        )
        let start = TestVideos.time(0)

        // Two buffers 285 seconds apart while the encoder rejects every write.
        let early = try TestVideos.audioBuffer(frames: 960, at: 0) { _, _ in 0.2 }
        let late = try TestVideos.audioBuffer(frames: 960, at: 285) { _, _ in 0.8 }
        try mixer.append(early, from: .system, at: early.presentationTimeStamp, startTime: start) { _ in false }
        #expect(mixer.bufferedFrames == 960)
        try mixer.append(late, from: .system, at: late.presentationTimeStamp, startTime: start) { _ in false }
        // Silence between 0 s and 285 s is never materialized; queued PCM stays capped at 1,440 frames.
        #expect(mixer.bufferedFrames == 1_440)
    }

    @Test func audioPastMaximumDurationIsTruncated() throws {
        let mixer = try AudioMixer(sources: [.system], maximumDuration: CMTime(value: 1, timescale: 1))
        let start = TestVideos.time(0)
        var emitted: [CMSampleBuffer] = []

        // Buffer spans 0.99 s .. 1.01 s; only the first 0.01 s (480 frames) should be kept.
        let tail = try TestVideos.audioBuffer(frames: 960, at: 0.99) { _, _ in 0.25 }
        let past = try TestVideos.audioBuffer(frames: 960, at: 1.05) { _, _ in 0.75 }
        try mixer.append(tail, from: .system, at: tail.presentationTimeStamp, startTime: start) { emitted.append($0); return true }
        try mixer.append(past, from: .system, at: past.presentationTimeStamp, startTime: start) { emitted.append($0); return true }
        try mixer.flush(upTo: TestVideos.time(2), startTime: start) { emitted.append($0); return true }

        let frames = extractFloats(from: emitted).count / 2
        #expect(frames == 48_000)
    }

    @Test func backpressureDuringALongSilenceGapPreservesResumedAudio() throws {
        let mixer = try AudioMixer(sources: [.system], maximumDuration: CMTime(value: 30, timescale: 1))
        let start = TestVideos.time(0)
        var emitted: [CMSampleBuffer] = []

        let first = try TestVideos.audioBuffer(frames: 960, at: 0) { _, _ in 0.2 }
        try mixer.append(first, from: .system, at: first.presentationTimeStamp, startTime: start) {
            emitted.append($0)
            return true
        }

        // Audio resumes at 2.0 s, but the encoder only accepts 3 silence chunks before stalling.
        let resumed = try TestVideos.audioBuffer(frames: 960, at: 2.0) { _, _ in 0.75 }
        var acceptedWhileBusy = 0
        try mixer.append(resumed, from: .system, at: resumed.presentationTimeStamp, startTime: start) { buffer in
            guard acceptedWhileBusy < 3 else { return false }
            acceptedWhileBusy += 1
            emitted.append(buffer)
            return true
        }
        #expect(acceptedWhileBusy == 3)

        // Once the encoder drains (or at finish), all remaining silence and resumed audio arrive intact.
        try mixer.flush(upTo: TestVideos.time(2.02), startTime: start) {
            emitted.append($0)
            return true
        }

        let samples = extractFloats(from: emitted)
        #expect(samples.count == 96_960 * 2)
        #expect(samples[50_000 * 2] == 0)
        #expect(abs(samples[96_000 * 2] - 0.75) < 0.001)
    }

    @Test func microphoneTimestampConversionPassesThroughWithoutSourceClockAndConvertsAcrossClocks() {
        let hostClock = CMClockGetHostTimeClock()
        let time = CMTime(seconds: 12.5, preferredTimescale: 1_000_000_000)
        #expect(MicrophoneCapture.convertTimestamp(time, from: nil, to: hostClock) == time)

        let converted = MicrophoneCapture.convertTimestamp(time, from: hostClock, to: hostClock)
        #expect(abs(converted.seconds - time.seconds) < 0.001)
    }

    private func extractFloats(from buffers: [CMSampleBuffer]) -> [Float] {
        var samples: [Float] = []
        for buffer in buffers {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &pointer
            ) == kCMBlockBufferNoErr, let pointer else { continue }
            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
                samples.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
            }
        }
        return samples
    }
}
