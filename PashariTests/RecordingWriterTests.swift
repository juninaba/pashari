import AVFoundation
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

    private func isClose(_ color: TestImages.RGBA, to expected: TestImages.RGBA) -> Bool {
        let channels = [
            (color.red, expected.red),
            (color.green, expected.green),
            (color.blue, expected.blue),
        ]
        return channels.allSatisfy { abs(Int($0) - Int($1)) <= 6 }
    }
}
