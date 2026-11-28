import AVFoundation
import ScreenCaptureKit
import Testing

@testable import Pashari

struct RecordingWriterTests {
    @Test func theLastFrameShowsUntilTheRecordingStops() async throws {
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // The screen changed three times, then stood still until Stop.
        let duration = try await TestVideos.makeMP4(
            at: url,
            frames: [(.blue, 0), (.red, 0.1), (.blue, 0.2)],
            end: 2
        )

        #expect(duration == 2)
        let samples = try await TestVideos.samples(in: url)
        #expect(samples.map(\.time) == [0, 0.1, 0.2])
        let last = try #require(samples.last)
        #expect(abs(last.time + last.duration - 2) < 0.001)
        let asset = AVURLAsset(url: url)
        #expect(try await asset.load(.duration).seconds == 2)
    }

    @Test func aRecordingIsAnH264VideoOfTheFramesSize() async throws {
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await TestVideos.makeMP4(at: url, width: 64, height: 48, frames: [(.blue, 0)], end: 1)

        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 64, height: 48))
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
    }

    @Test func aRecordingStopsAtFiveMinutes() async throws {
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try RecordingWriter(url: url, width: 64, height: 48)
        let frame = TestVideos.frame(width: 64, height: 48, color: .blue)

        #expect(try writer.append(frame, at: TestVideos.time(0)) == .appended)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try writer.append(frame, at: TestVideos.time(299.9)) == .appended)
        #expect(try writer.append(frame, at: TestVideos.time(300)) == .full)
        let duration = try await TestVideos.finish(writer, at: 400)

        #expect(duration == 300)
        #expect(try await AVURLAsset(url: url).load(.duration).seconds == 300)
    }

    @Test func aFrameOlderThanTheLastIsLeftOut() async throws {
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try RecordingWriter(url: url, width: 64, height: 48)
        let frame = TestVideos.frame(width: 64, height: 48, color: .blue)

        #expect(try writer.append(frame, at: TestVideos.time(1)) == .appended)
        #expect(try writer.append(frame, at: TestVideos.time(0.5)) == .dropped)
        writer.cancel()
    }

    @Test func aRecordingThatGotNoFrameLeavesNoFile() async throws {
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try RecordingWriter(url: url, width: 64, height: 48)

        let duration = try await TestVideos.finish(writer, at: 1)

        #expect(duration == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func cancellingDeletesTheFile() async throws {
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try RecordingWriter(url: url, width: 64, height: 48)
        _ = try writer.append(TestVideos.frame(width: 64, height: 48, color: .blue), at: TestVideos.time(0))

        writer.cancel()

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func theColoursOfTheFramesAreKept() async throws {
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gray = TestImages.RGBA(red: 128, green: 128, blue: 128, alpha: 255)

        try await TestVideos.makeMP4(at: url, frames: [(.red, 0), (gray, 1)], end: 2)

        let red = TestImages.pixel(of: try await TestVideos.image(in: url, at: 0.5), x: 32, y: 24)
        let middle = TestImages.pixel(of: try await TestVideos.image(in: url, at: 1.5), x: 32, y: 24)
        #expect(isClose(red, to: .red), "\(red)")
        #expect(isClose(middle, to: gray), "\(middle)")
    }

    @Test func aSilentRecordingHasNoAudioTrack() async throws {
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await TestVideos.makeMP4(at: url, width: 64, height: 48, frames: [(.blue, 0)], end: 1)

        let audioTracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        #expect(audioTracks.isEmpty)
    }

    @Test func aRecordingWithSystemAudioAndMicrophoneMixesIntoOneStereoAACTrack() async throws {
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try RecordingWriter(
            url: url,
            width: 64,
            height: 48,
            audioSources: [.system, .microphone],
            isRealTime: false
        )
        let frame = TestVideos.frame(width: 64, height: 48, color: .blue)

        // Audio arriving before the first video frame is ignored cleanly.
        let early = try TestVideos.audioBuffer(frames: 960, at: -0.05) { _, _ in 0.5 }
        try writer.appendAudio(early, from: .system)

        #expect(try writer.append(frame, at: TestVideos.time(0)) == .appended)
        // 0.0..0.5 s: system tone on Left (440 Hz), silence on Right; mic mono tone on 0.5..1.0 s (880 Hz).
        for chunk in 0..<50 {
            let startSec = Double(chunk) * 0.02
            let system = try TestVideos.audioBuffer(frames: 960, at: startSec) { index, channel in
                guard startSec < 0.5, channel == 0 else { return 0 }
                let t = startSec + Double(index) / 48_000
                return Float(sin(2 * .pi * 440 * t)) * 0.4
            }
            let mic = try TestVideos.audioBuffer(channels: 1, interleaved: false, frames: 960, at: startSec) { index, _ in
                guard startSec >= 0.5 else { return 0 }
                let t = startSec + Double(index) / 48_000
                return Float(sin(2 * .pi * 880 * t)) * 0.4
            }
            try writer.appendAudio(system, from: .system)
            try writer.appendAudio(mic, from: .microphone)
        }
        let duration = try await TestVideos.finish(writer, at: 1)

        #expect(duration == 1)
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(audioTracks.count == 1)
        let format = try #require(try await audioTracks[0].load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
        #expect(asbd.mSampleRate == 48_000)
        #expect(asbd.mChannelsPerFrame == 2)

        let samples = try await TestVideos.decodedAudioSamples(in: url)
        // First half: system audio on Left, silent on Right.
        #expect(TestVideos.rms(of: samples, channel: 0, from: 0.1, to: 0.4) > 0.2)
        #expect(TestVideos.rms(of: samples, channel: 1, from: 0.1, to: 0.4) < 0.02)
        // Second half: mono microphone centered on both Left and Right.
        #expect(TestVideos.rms(of: samples, channel: 0, from: 0.6, to: 0.9) > 0.2)
        #expect(TestVideos.rms(of: samples, channel: 1, from: 0.6, to: 0.9) > 0.2)

        // Recovery metadata still parses video size and duration with an audio track present.
        let info = try #require(RecordingFileInfo(contentsOf: url))
        #expect(info.pixelSize == CGSize(width: 64, height: 48))
        #expect(abs(info.duration - 1) < 0.05)
    }

    @Test func audioEnabledWithNoAudioBuffersStillFinishesCleanly() async throws {
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try RecordingWriter(
            url: url,
            width: 64,
            height: 48,
            audioSources: [.system],
            isRealTime: false
        )
        let frame = TestVideos.frame(width: 64, height: 48, color: .blue)

        #expect(try writer.append(frame, at: TestVideos.time(0)) == .appended)
        let duration = try await TestVideos.finish(writer, at: 0.5)

        #expect(duration == 0.5)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aRecordingWithAudioStopsAtFiveMinutes() async throws {
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try RecordingWriter(
            url: url,
            width: 64,
            height: 48,
            audioSources: [.system],
            isRealTime: false
        )
        let frame = TestVideos.frame(width: 64, height: 48, color: .blue)

        #expect(try writer.append(frame, at: TestVideos.time(0)) == .appended)
        let early = try TestVideos.audioBuffer(frames: 960, at: 0) { _, _ in 0.2 }
        try writer.appendAudio(early, from: .system)
        #expect(try writer.append(frame, at: TestVideos.time(299.9)) == .appended)
        let late = try TestVideos.audioBuffer(frames: 960, at: 300.5) { _, _ in 0.5 }
        try writer.appendAudio(late, from: .system)
        #expect(try writer.append(frame, at: TestVideos.time(300)) == .full)
        let duration = try await TestVideos.finish(writer, at: 400)

        #expect(duration == 300)
        #expect(abs(try await AVURLAsset(url: url).load(.duration).seconds - 300) < 0.05)
    }

    @Test func realTimeAudioResumingAfterALongGapKeepsTheFullTrackAndResumedSound() async throws {
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try RecordingWriter(
            url: url,
            width: 64,
            height: 48,
            audioSources: [.system],
            isRealTime: true
        )
        let frame = TestVideos.frame(width: 64, height: 48, color: .blue)

        #expect(try writer.append(frame, at: TestVideos.time(0)) == .appended)
        let opening = try TestVideos.audioBuffer(frames: 960, at: 0) { index, _ in
            Float(sin(2 * .pi * 440 * Double(index) / 48_000)) * 0.4
        }
        try writer.appendAudio(opening, from: .system)

        // Twenty-second dropout, then audio resumes for one second on a real-time writer.
        for chunk in 0..<50 {
            let startSec = 20.0 + Double(chunk) * 0.02
            let resumed = try TestVideos.audioBuffer(frames: 960, at: startSec) { index, _ in
                let t = startSec + Double(index) / 48_000
                return Float(sin(2 * .pi * 880 * t)) * 0.4
            }
            try writer.appendAudio(resumed, from: .system)
        }
        let duration = try await TestVideos.finish(writer, at: 21)

        #expect(duration == 21)
        let asset = AVURLAsset(url: url)
        let audioTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let audioDuration = try await audioTrack.load(.timeRange).duration.seconds
        #expect(abs(audioDuration - 21) < 0.1, "audio ended early at \(audioDuration) s")
        let samples = try await TestVideos.decodedAudioSamples(in: url)
        #expect(TestVideos.rms(of: samples, channel: 0, from: 5.0, to: 15.0) < 0.01)
        #expect(TestVideos.rms(of: samples, channel: 0, from: 20.1, to: 20.9) > 0.2)
    }

    @Test func audioStraddlingStopTimeLeavesNoPostStopAudioEncodedInTheFile() async throws {
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try RecordingWriter(
            url: url,
            width: 64,
            height: 48,
            audioSources: [.system],
            isRealTime: true
        )
        let frame = TestVideos.frame(width: 64, height: 48, color: .blue)
        #expect(try writer.append(frame, at: TestVideos.time(0)) == .appended)

        let stopAt = TestVideos.time(0.21)
        // First 200 ms: silent.
        for chunk in 0..<10 {
            let silent = try TestVideos.audioBuffer(frames: 960, at: Double(chunk) * 0.02) { _, _ in 0 }
            try writer.appendAudio(silent, from: .system, upTo: stopAt)
        }
        // Buffer straddles stopAt (0.20..0.22): silent before 0.21, loud tone after 0.21.
        let straddling = try TestVideos.audioBuffer(frames: 960, at: 0.20) { index, _ in
            guard index >= 480 else { return 0 }
            return Float(sin(2 * .pi * 1000 * Double(index) / 48_000)) * 0.8
        }
        try writer.appendAudio(straddling, from: .system, upTo: stopAt)
        let duration = try await TestVideos.finish(writer, at: 0.21)

        #expect(abs((duration ?? 0) - 0.21) < 0.005)
        let samples = try await TestVideos.decodedAudioSamples(in: url)
        let peak = samples.map(abs).max() ?? 0
        #expect(peak < 0.02, "post-stop tone leaked into AAC output (peak \(peak))")
    }

    @Test func disablingMicrophoneSourceLetsSystemAudioWriteWithoutWaiting() async throws {
        let url = try TestVideos.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try RecordingWriter(
            url: url,
            width: 64,
            height: 48,
            audioSources: [.system, .microphone],
            isRealTime: true
        )
        writer.disableAudioSource(.microphone)
        let frame = TestVideos.frame(width: 64, height: 48, color: .blue)
        #expect(try writer.append(frame, at: TestVideos.time(0)) == .appended)
        let system = try TestVideos.audioBuffer(frames: 960, at: 0) { index, _ in
            Float(sin(2 * .pi * 440 * Double(index) / 48_000)) * 0.5
        }
        try writer.appendAudio(system, from: .system)
        // With microphone disabled, system audio emits immediately rather than waiting for the microphone.
        #expect(!writer.hasPendingAudio)
        _ = try await TestVideos.finish(writer, at: 0.1)

        if #available(macOS 15.0, *) {
            let micError = NSError(
                domain: SCStreamErrorDomain,
                code: SCStreamError.Code.failedToStartMicrophoneCapture.rawValue
            )
            let otherError = NSError(
                domain: SCStreamErrorDomain,
                code: SCStreamError.Code.failedToStart.rawValue
            )
            #expect(ScreenRecorder.isMicrophoneStartError(micError))
            #expect(!ScreenRecorder.isMicrophoneStartError(otherError))
        }
    }

    private func isClose(_ color: TestImages.RGBA, to expected: TestImages.RGBA) -> Bool {
        let channels = [
            (color.red, expected.red),
            (color.green, expected.green),
            (color.blue, expected.blue),
        ]
        return channels.allSatisfy { abs(Int($0) - Int($1)) <= 6 }
    }
}
