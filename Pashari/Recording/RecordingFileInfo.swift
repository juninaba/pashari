import CoreGraphics
import Foundation

/// What restoring a recording needs to know of its MP4: whether it was
/// finished, and how large and how long it is.
///
/// It is read straight from the boxes the file is made of, because
/// AVFoundation only answers asynchronously, and recordings are restored
/// while the folders they come from are locked (see `CaptureStorage`).
struct RecordingFileInfo: Equatable {
    /// The video's size, in pixels.
    let pixelSize: CGSize
    let duration: TimeInterval

    /// Nil when the file is not a finished MP4. A recording that was cut
    /// short, say by a crash, lacks the index (the "moov" box) that is
    /// written last, and cannot be played.
    init?(contentsOf url: URL) {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard
            let moov = Self.topLevelBox("moov", in: file),
            let header = Self.children(of: moov)["mvhd"],
            let (timescale, length) = Self.movieDuration(in: header),
            timescale > 0,
            let size = Self.videoSize(in: moov)
        else { return nil }
        pixelSize = size
        duration = Double(length) / Double(timescale)
    }

    // MARK: - Boxes

    /// The index lies at the start of Pashari's recordings, but may follow
    /// the media in others, so the file is walked box by box rather than
    /// read whole.
    private static func topLevelBox(_ type: String, in file: FileHandle) -> Data? {
        guard let end = try? file.seekToEnd() else { return nil }
        var offset: UInt64 = 0
        while offset + 8 <= end {
            guard (try? file.seek(toOffset: offset)) != nil, let head = try? file.read(upToCount: 16) else { return nil }
            guard let (size, headerLength, name) = boxHeader(in: head, at: 0, available: end - offset) else { return nil }
            if name == type {
                // The index of a five minute recording is well under this.
                guard size - UInt64(headerLength) <= 64_000_000 else { return nil }
                try? file.seek(toOffset: offset + UInt64(headerLength))
                return try? file.read(upToCount: Int(size) - headerLength)
            }
            offset += size
        }
        return nil
    }

    /// The boxes inside `data`, by type; the first of each type.
    private static func children(of data: Data) -> [String: Data] {
        var boxes: [String: Data] = [:]
        forEachChild(of: data) { name, payload in
            if boxes[name] == nil { boxes[name] = payload }
        }
        return boxes
    }

    private static func forEachChild(of data: Data, _ body: (String, Data) -> Void) {
        var offset = 0
        while offset + 8 <= data.count {
            guard let (size, headerLength, name) = boxHeader(in: data, at: offset, available: UInt64(data.count - offset))
            else { return }
            let start = data.startIndex + offset
            body(name, data.subdata(in: (start + headerLength)..<(start + Int(size))))
            offset += Int(size)
        }
    }

    /// A box's size, the length of its header, and its type. Nil when the
    /// box would run past what is `available`.
    private static func boxHeader(in data: Data, at offset: Int, available: UInt64) -> (UInt64, Int, String)? {
        guard data.count >= offset + 8 else { return nil }
        var size = UInt64(uint32(in: data, at: offset))
        let name = String(decoding: data[(data.startIndex + offset + 4)..<(data.startIndex + offset + 8)], as: UTF8.self)
        var headerLength = 8
        if size == 1 {
            guard data.count >= offset + 16 else { return nil }
            size = (UInt64(uint32(in: data, at: offset + 8)) << 32) | UInt64(uint32(in: data, at: offset + 12))
            headerLength = 16
        } else if size == 0 {
            size = available
        }
        guard size >= UInt64(headerLength), size <= available else { return nil }
        return (size, headerLength, name)
    }

    /// The timescale and the length in it, from a "mvhd" box.
    private static func movieDuration(in header: Data) -> (UInt32, UInt64)? {
        guard let version = header.first else { return nil }
        if version == 1 {
            guard header.count >= 32 else { return nil }
            let length = (UInt64(uint32(in: header, at: 24)) << 32) | UInt64(uint32(in: header, at: 28))
            return (uint32(in: header, at: 20), length)
        }
        guard header.count >= 20 else { return nil }
        return (uint32(in: header, at: 12), UInt64(uint32(in: header, at: 16)))
    }

    /// The size of the first video track, from the end of its "tkhd" box:
    /// width and height, as 16.16 fixed-point numbers.
    private static func videoSize(in moov: Data) -> CGSize? {
        var size: CGSize?
        forEachChild(of: moov) { name, track in
            guard size == nil, name == "trak" else { return }
            let boxes = children(of: track)
            guard
                let media = boxes["mdia"],
                let handler = children(of: media)["hdlr"],
                handler.count >= 12,
                String(decoding: handler[(handler.startIndex + 8)..<(handler.startIndex + 12)], as: UTF8.self) == "vide",
                let header = boxes["tkhd"],
                header.count >= 8
            else { return }
            let width = Double(uint32(in: header, at: header.count - 8)) / 65536
            let height = Double(uint32(in: header, at: header.count - 4)) / 65536
            size = CGSize(width: width, height: height)
        }
        return size
    }

    private static func uint32(in data: Data, at offset: Int) -> UInt32 {
        data[(data.startIndex + offset)..<(data.startIndex + offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }
}
