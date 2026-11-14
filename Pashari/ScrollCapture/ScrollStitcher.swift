import CoreGraphics
import Foundation

/// Joins the frames of an area that the user scrolls into one tall picture.
///
/// Each frame is compared with the last one that found its place, a row of
/// pixels at a time. Every row gets a fingerprint, and the distance at which
/// the most fingerprints of the two frames line up is how far the content
/// scrolled. Rows that scroll into view are added to the bottom of the
/// picture.
///
/// Above and below the content there may be rows that do not scroll along:
/// a toolbar, a page's fixed header or footer, or a see-through bar that
/// shows the content blurred. Only the rows from the first to the last one
/// that moved with the content go into the picture, plus those that just
/// scrolled into view. The rest is the header and the footer, which the
/// picture gets once, at its top from the first frame and at its bottom
/// from the last.
///
/// Frames are 4 bytes per pixel. The stitcher only copies bytes around, so
/// the channel order is up to the caller (`makeImage` expects BGRA).
nonisolated struct ScrollStitcher {
    /// One frame's pixels, top row first. The pointer only needs to stay
    /// valid during the call the frame is passed to.
    struct Frame {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let pixels: UnsafeRawPointer

        func row(_ y: Int) -> UnsafeRawPointer {
            pixels + y * bytesPerRow
        }
    }

    enum Outcome: Equatable {
        /// The first frame, which is the whole picture so far.
        case started
        case unchanged
        /// The content scrolled by this many rows: down when positive, up
        /// when negative.
        case scrolled(Int)
        /// Part of the content changed without scrolling, say an image that
        /// finished loading. Later frames are compared with its new look.
        case changedInPlace
        /// The content changed too much to tell where it went, most likely
        /// because it scrolled further between two frames than the area is
        /// tall. The frame is left out; once the content is back where a
        /// frame can be placed, the picture carries on.
        case lost
        /// A change too small to place, such as a blinking text cursor. The
        /// frame is left out.
        case ignored
        /// The picture has reached `maximumHeight`. This frame and all later
        /// ones are left out.
        case full
    }

    let width: Int
    let height: Int
    let maximumHeight: Int

    /// Rows of the picture from the top down, without the footer, 4 bytes
    /// per pixel with no padding.
    ///
    /// `Data` rather than `[UInt8]`, here and for `lastFrame`: Foundation
    /// copies its bytes in bulk even in a debug build, where an array would
    /// copy one byte at a time.
    private var canvas = Data()
    /// The row of the canvas that the top of the last placed frame shows.
    private var frameTop = 0
    /// The rows at the top of the canvas that show the first frame's header.
    /// Unknown (nil) until the content first scrolls.
    private var canvasHeader: Int?
    /// How many rows at the top and bottom of the last placed frame did not
    /// scroll along. Unknown (nil) until the content first scrolls.
    private var header: Int?
    private var footer: Int?
    private var lastFrame = Data()
    private var lastFingerprints: Fingerprints?
    private var isFull = false

    private let rowLength: Int
    private let fingerprintLength: Int

    /// Rows that occur more often than this in a frame, such as blank lines,
    /// say nothing about how far the content moved.
    private static let maximumRepeats = 3
    /// The fewest rows that must line up before a shift is believed.
    private static let minimumSupport = 8
    /// Of the rows that should line up at a shift, at least this share must,
    /// for the shift to be believed. Not all of them: some can change while
    /// scrolling, such as a playing video or the scroll bar.
    private static let minimumAgreement = 0.4

    /// `ignoringRightColumns` leaves that many columns at the right edge out
    /// of the comparison. That is where scroll bars appear while scrolling,
    /// and they move differently from the content.
    init(width: Int, height: Int, maximumHeight: Int, ignoringRightColumns: Int = 0) {
        precondition(width > 0 && height > 0, "A frame needs at least one pixel")
        self.width = width
        self.height = height
        self.maximumHeight = max(maximumHeight, height)
        rowLength = width * 4
        let ignored = min(max(ignoringRightColumns, 0), width - 1)
        fingerprintLength = (width - ignored) * 4
    }

    var pictureHeight: Int {
        canvasHeight + (footer ?? 0)
    }

    private var canvasHeight: Int {
        canvas.count / rowLength
    }

    // MARK: - Adding frames

    mutating func add(_ frame: Frame) -> Outcome {
        precondition(frame.width == width && frame.height == height, "Every frame must be the same size")
        guard !isFull else { return .full }
        let fingerprints = Fingerprints(of: frame, length: fingerprintLength)

        guard let last = lastFingerprints else {
            keep(frame, fingerprints)
            canvas = lastFrame
            return .started
        }

        // The rows at the top and bottom that did not change.
        var top = 0
        while top < height, fingerprints.values[top] == last.values[top] {
            top += 1
        }
        guard top < height else { return .unchanged }
        var bottom = height
        while fingerprints.values[bottom - 1] == last.values[bottom - 1] {
            bottom -= 1
        }

        guard
            let shift = Self.shift(from: last, to: fingerprints, within: top..<bottom)
                ?? inPlaceChange(of: fingerprints, unchangedAbove: top, below: bottom)
        else {
            return (bottom - top) * 3 >= height ? .lost : .ignored
        }

        guard shift != 0 else {
            // Nothing moved, so nothing new joins the picture. Something that
            // appeared in place, such as a tooltip or a bar sliding in, would
            // only spoil it. Later frames are compared with the new look, and
            // bring the changed rows along once they scroll.
            keep(frame, fingerprints)
            return .changedInPlace
        }

        let fixed = Self.fixedRows(from: last, to: fingerprints, shift: shift)
            ?? (header: top, footer: height - bottom)
        if canvasHeader == nil {
            // The first scroll. Until now the whole first frame stood in for
            // the content, but its bottom rows are the footer, which goes in
            // at the end, from the last frame.
            canvasHeader = fixed.header
            canvas.removeSubrange((height - fixed.footer) * rowLength..<canvas.count)
        } else if let footer, fixed.footer < footer {
            // Rows of the last frame just above its footer turn out to be
            // content, and may be about to scroll past the header unseen.
            let last = lastFrame
            last.withUnsafeBytes { bytes in
                let frame = Frame(width: width, height: height, bytesPerRow: rowLength, pixels: bytes.baseAddress!)
                write(rows: (height - footer)..<(height - fixed.footer), of: frame)
            }
        }
        header = fixed.header
        footer = fixed.footer
        frameTop += shift
        write(rows: fixed.header..<(height - fixed.footer), of: frame)
        keep(frame, fingerprints)

        return isFull ? .full : .scrolled(shift)
    }

    /// Copies rows of `frame` into the canvas. Rows the canvas already has
    /// get overwritten, so each part of the picture shows how it looked the
    /// last time it scrolled by: by then an image has loaded, and the scroll
    /// bar, which shows only while scrolling, has usually moved on.
    private mutating func write(rows: Range<Int>, of frame: Frame) {
        let rowLength = rowLength
        let canvasHeader = canvasHeader ?? 0
        let maximumCanvasHeight = maximumHeight - (footer ?? 0)
        for y in rows {
            let row = frameTop + y
            // Above that lies the header, or content scrolled back past the
            // start, which the picture does not grow upwards for.
            guard row >= canvasHeader else { continue }
            if row < canvasHeight {
                canvas.withUnsafeMutableBytes { canvas in
                    canvas.baseAddress!
                        .advanced(by: row * rowLength)
                        .copyMemory(from: frame.row(y), byteCount: rowLength)
                }
            } else {
                // Rows are only ever added right after the last one.
                guard row == canvasHeight else { return }
                guard canvasHeight < maximumCanvasHeight else {
                    isFull = true
                    return
                }
                canvas.append(frame.row(y).assumingMemoryBound(to: UInt8.self), count: rowLength)
            }
        }
    }

    private mutating func keep(_ frame: Frame, _ fingerprints: Fingerprints) {
        let (height, rowLength) = (height, rowLength)
        if lastFrame.isEmpty {
            lastFrame = Data(count: height * rowLength)
        }
        lastFrame.withUnsafeMutableBytes { copy in
            for y in 0..<height {
                copy.baseAddress!
                    .advanced(by: y * rowLength)
                    .copyMemory(from: frame.row(y), byteCount: rowLength)
            }
        }
        lastFingerprints = fingerprints
    }

    // MARK: - Finding the shift

    /// Every row's fingerprint, and the rows where each fingerprint occurs.
    struct Fingerprints {
        let values: [UInt64]
        let rows: [UInt64: [Int]]

        init(values: [UInt64]) {
            self.values = values
            var rows: [UInt64: [Int]] = [:]
            for (row, value) in values.enumerated() {
                rows[value, default: []].append(row)
            }
            self.rows = rows
        }

        init(of frame: Frame, length: Int) {
            self.init(values: (0..<frame.height).map { Self.fingerprint(of: frame.row($0), length: length) })
        }

        func isDistinctive(_ value: UInt64) -> Bool {
            (rows[value]?.count ?? 0) <= ScrollStitcher.maximumRepeats
        }

        /// Swift's own 64-bit hash of the row's bytes. The standard library
        /// is always built optimised, so this stays fast in a debug build,
        /// where a hash loop written here would take several times as long
        /// as the frames have between them. The hash is seeded anew for each
        /// run of the app, which does not matter: fingerprints are only ever
        /// compared with others from the same run.
        static func fingerprint(of row: UnsafeRawPointer, length: Int) -> UInt64 {
            var hasher = Hasher()
            hasher.combine(bytes: UnsafeRawBufferPointer(start: row, count: length))
            return UInt64(bitPattern: Int64(hasher.finalize()))
        }
    }

    /// How far the content within `band` moved from `old` to `new`, in rows,
    /// or nil when that cannot be told. Positive means it moved up, that is,
    /// the user scrolled down.
    ///
    /// Each distinctive row of `new` votes for the shifts at which `old` has
    /// the same row. The shift with the most votes wins, and ties go to the
    /// smaller shift, since frames come many times a second.
    static func shift(from old: Fingerprints, to new: Fingerprints, within band: Range<Int>) -> Int? {
        let span = band.count
        guard span > 0 else { return nil }
        // votes[shift + span - 1] counts the rows that line up at `shift`.
        var votes = [Int](repeating: 0, count: 2 * span - 1)
        for row in band {
            let value = new.values[row]
            guard
                new.isDistinctive(value),
                old.isDistinctive(value),
                let oldRows = old.rows[value]
            else { continue }
            for oldRow in oldRows where band.contains(oldRow) {
                votes[oldRow - row + span - 1] += 1
            }
        }

        var best = 0
        var bestVotes = votes[span - 1]
        for distance in 1..<span {
            if votes[span - 1 + distance] > bestVotes {
                best = distance
                bestVotes = votes[span - 1 + distance]
            }
            if votes[span - 1 - distance] > bestVotes {
                best = -distance
                bestVotes = votes[span - 1 - distance]
            }
        }
        guard bestVotes >= minimumSupport else { return nil }

        // The rows of `new` that should line up if `best` is right.
        var expected = 0
        for row in band where band.contains(row + best) && new.isDistinctive(new.values[row]) {
            expected += 1
        }
        guard Double(bestVotes) >= minimumAgreement * Double(expected) else { return nil }
        return best
    }

    /// The rows at the top and bottom of `new` that did not scroll along
    /// with the content, which moved by `shift` (not zero) since `old`.
    ///
    /// A row moved along when it is the row `shift` further on in `old`, and
    /// not merely the same as before: blank rows look alike either way, and
    /// count as not moving. That errs on the safe side, since rows taken for
    /// the header or footer are simply not copied this time. Rows that just
    /// scrolled into view have nothing to match yet; they lie between the
    /// last moving row and the footer, or between the header and the first.
    static func fixedRows(
        from old: Fingerprints,
        to new: Fingerprints,
        shift: Int
    ) -> (header: Int, footer: Int)? {
        let height = new.values.count
        var first: Int?
        var last: Int?
        for row in max(0, -shift)..<min(height, height - shift) {
            let value = new.values[row]
            if value == old.values[row + shift], value != old.values[row] {
                first = first ?? row
                last = row
            }
        }
        guard let first, let last else { return nil }
        return shift > 0
            ? (header: first, footer: height - shift - last - 1)
            : (header: first + shift, footer: height - last - 1)
    }

    /// Recognises a change in place, such as an image that loaded, when no
    /// shift can be found: the content rows around the change are still
    /// where they were. Rows of the header and footer do not count, since
    /// they stay put while the content scrolls, so this can only be told
    /// once those are known.
    private func inPlaceChange(
        of fingerprints: Fingerprints,
        unchangedAbove top: Int,
        below bottom: Int
    ) -> Int? {
        guard let header, let footer, header < height - footer else { return nil }
        var distinctive = 0
        for row in header..<height - footer where row < top || row >= bottom {
            if fingerprints.isDistinctive(fingerprints.values[row]) {
                distinctive += 1
            }
        }
        return distinctive >= Self.minimumSupport ? 0 : nil
    }

    // MARK: - The picture

    /// The picture so far: the canvas, then the footer from the last frame.
    /// The pixels are read as BGRA, the layout ScreenCaptureKit delivers.
    func makeImage(colorSpace: CGColorSpace) -> CGImage? {
        guard !canvas.isEmpty else { return nil }
        var pixels = canvas
        if let footer, footer > 0 {
            pixels.append(lastFrame.subdata(in: ((height - footer) * rowLength)..<lastFrame.count))
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(
            width: width,
            height: pixels.count / rowLength,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: rowLength,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
