import Accelerate
import CoreGraphics
import Foundation

/// Joins the frames of an area that the user scrolls into one tall picture.
///
/// Each frame is compared with the last one that found its place, a row of
/// pixels at a time. The distance at which the most rows of the two frames
/// look alike is how far the content scrolled. Rows that scroll into view
/// are added to the bottom of the picture.
///
/// Rows are compared by their brightness in a few dozen blocks across, with
/// a little room for error. macOS adds faint noise to the colours each time
/// it draws something (dithering), so the same content is never exactly the
/// same twice, and averaging over a block smooths the noise out.
///
/// Above and below the content there may be rows that do not scroll along:
/// a toolbar, a page's fixed header or footer, or a see-through bar that
/// shows the content blurred. Only the rows from the first to the last one
/// that moved with the content go into the picture, plus those that just
/// scrolled into view. The rest is the header and the footer, which the
/// picture gets once: at its top as it looked when the scrolling began,
/// and at its bottom from the last frame. Of the looks a row had on its
/// way through the area, the picture keeps the one from nearest the
/// middle, well away from any bar.
///
/// Frames are 4 bytes per pixel, in BGRA order, as ScreenCaptureKit
/// delivers them.
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
        /// A change too small to place, such as a blinking text cursor, or
        /// before the first scroll one that may be in place, such as a
        /// playing video. The frame is left out.
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
    /// For each canvas row, how far from the middle of the area it was when
    /// the look the canvas has was taken.
    private var canvasDistances: [Int] = []
    /// The row of the canvas that the top of the last placed frame shows.
    private var frameTop = 0
    /// The middle of the last placed frame's content, between its header and
    /// its footer.
    private var lastMiddle = 0
    /// The rows at the top of the canvas that show the first frame's header.
    /// Unknown (nil) until the content first scrolls.
    private var canvasHeader: Int?
    /// How many rows at the top and bottom of the last placed frame did not
    /// scroll along. Unknown (nil) until the content first scrolls.
    private var header: Int?
    private var footer: Int?
    private var lastFrame = Data()
    private var lastSignatures: Signatures?
    private var lastChangedRows = 0..<0
    private var lastBackfilledRows = 0..<0
    private var isFull = false

    private let rowLength: Int
    private let summarizer: Summarizer

    /// How much two rows' block brightnesses may differ, on a scale of 0 to
    /// 255, for the rows to count as the same. The noise from dithering
    /// moves them by well under one.
    static let tolerance: Float = 1.5
    /// A row that matches more rows than this, such as a blank line, says
    /// nothing about how far the content moved.
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
        summarizer = Summarizer(comparedWidth: width - ignored)
    }

    var pictureHeight: Int {
        canvasHeight + (footer ?? 0)
    }

    /// How tall the stitched content is so far, in pixels, without the fixed
    /// footer or blank spring-back space at the end.
    private(set) var stitchedContentHeight = 0

    /// Whether the last placed frame covers any of the bottom `maximumRows`
    /// rows of the stitched content.
    func lastFrameOverlapsTail(maximumRows: Int) -> Bool {
        let frameStart = max(frameTop + (header ?? 0), canvasHeader ?? 0)
        let frameEnd = frameTop + height - (footer ?? 0)
        return overlapsTail(frameStart..<max(frameStart, frameEnd), maximumRows: maximumRows)
    }

    /// Whether the rows changed by the last `.changedInPlace` frame overlap the
    /// bottom `maximumRows` rows of the stitched content.
    func lastChangeOverlapsTail(maximumRows: Int) -> Bool {
        overlapsTail(lastChangedRows, maximumRows: maximumRows)
    }

    /// Whether rows written back when a fixed footer shrank overlap the bottom
    /// `maximumRows` rows of the stitched content.
    func lastBackfillOverlapsTail(maximumRows: Int) -> Bool {
        overlapsTail(lastBackfilledRows, maximumRows: maximumRows)
    }

    private func overlapsTail(_ rows: Range<Int>, maximumRows: Int) -> Bool {
        guard maximumRows > 0, stitchedContentHeight > 0, !rows.isEmpty else { return false }
        let tailStart = max(0, stitchedContentHeight - maximumRows)
        return max(rows.lowerBound, tailStart) < min(rows.upperBound, stitchedContentHeight)
    }

    private var canvasHeight: Int {
        canvas.count / rowLength
    }

    // MARK: - Adding frames

    mutating func add(_ frame: Frame) -> Outcome {
        precondition(frame.width == width && frame.height == height, "Every frame must be the same size")
        guard !isFull else { return .full }
        let signatures = summarizer.signatures(of: frame)

        guard let last = lastSignatures else {
            keep(frame, signatures)
            canvas = lastFrame
            lastMiddle = height / 2
            canvasDistances = (0..<height).map { abs($0 - lastMiddle) }
            stitchedContentHeight = height
            return .started
        }

        // The rows at the top and bottom that did not change.
        let changes = signatures.distances(0..<height, to: last, from: 0)
        var top = 0
        while top < height, changes[top] <= Self.tolerance {
            top += 1
        }
        guard top < height else {
            // It may still differ where frames are not compared: the scroll
            // bar may have faded.
            keepLatestLook(frame, signatures)
            return .unchanged
        }
        var bottom = height
        while changes[bottom - 1] <= Self.tolerance {
            bottom -= 1
        }

        guard
            let shift = Self.shift(from: last, to: signatures, within: top..<bottom)
                ?? inPlaceChange(of: signatures, unchangedAbove: top, below: bottom)
        else {
            // Most likely the content scrolled too far, if a third of the
            // area or more changed. Until the first scroll, though, a change
            // in place, such as a playing video, cannot be told yet, so only
            // a change over most of the area counts as lost.
            let thirds = canvasHeader == nil ? 2 : 1
            return (bottom - top) * 3 >= height * thirds ? .lost : .ignored
        }

        guard shift != 0 else {
            // Nothing moved, so nothing new joins the picture. Something that
            // appeared in place, such as a tooltip or a bar sliding in, would
            // only spoil it once the content scrolls on. Later frames are
            // compared with the new look, and bring the changed rows along
            // once they scroll.
            keepLatestLook(frame, signatures)
            let changedStart = max(frameTop + max(top, header ?? 0), canvasHeader ?? 0)
            let changedEnd = frameTop + min(bottom, height - (footer ?? 0))
            lastChangedRows = changedStart < changedEnd ? changedStart..<changedEnd : 0..<0
            return .changedInPlace
        }

        let fixed = Self.fixedRows(from: last, to: signatures, shift: shift)
            ?? (header: top, footer: height - bottom)
        lastBackfilledRows = 0..<0
        if canvasHeader == nil {
            // The first scroll. Until now the whole first frame stood in for
            // the content, but its bottom rows are the footer, which goes in
            // at the end, from the last frame.
            canvasHeader = fixed.header
            canvas.removeSubrange((height - fixed.footer) * rowLength..<canvas.count)
            canvasDistances.removeSubrange((height - fixed.footer)...)
        } else if let footer, fixed.footer < footer {
            // Rows of the last frame just above its footer turn out to be
            // content, and may be about to scroll past the header unseen.
            let last = lastFrame
            let middle = lastMiddle
            last.withUnsafeBytes { bytes in
                let frame = Frame(width: width, height: height, bytesPerRow: rowLength, pixels: bytes.baseAddress!)
                write(rows: (height - footer)..<(height - fixed.footer), of: frame, middle: middle)
            }
            let backfillStart = max(frameTop + height - footer, canvasHeader ?? 0)
            let backfillEnd = frameTop + height - fixed.footer
            if backfillStart < backfillEnd {
                lastBackfilledRows = backfillStart..<backfillEnd
            }
        }
        header = fixed.header
        footer = fixed.footer
        frameTop += shift
        lastMiddle = (fixed.header + height - fixed.footer) / 2
        write(rows: fixed.header..<(height - fixed.footer), of: frame, middle: lastMiddle)
        keep(frame, signatures)
        stitchedContentHeight = pictureContentHeight

        return isFull ? .full : .scrolled(shift)
    }

    /// Copies rows of `frame` into the canvas, `middle` being the middle of
    /// its content. A row the canvas already has is replaced only by a look
    /// from nearer the middle of the area. By the edges a row may be dimmed
    /// or blurred under a see-through bar, which cannot always be told from
    /// content: under a bar that only dims, rows a few apart look alike in
    /// two frames, as if they had moved along. Nearer the middle the row
    /// shows plainly, and an image that loads on its way there shows too.
    private mutating func write(rows: Range<Int>, of frame: Frame, middle: Int) {
        let rowLength = rowLength
        let canvasHeader = canvasHeader ?? 0
        let maximumCanvasHeight = maximumHeight - (footer ?? 0)
        for y in rows {
            let row = frameTop + y
            // Above that lies the header, or content scrolled back past the
            // start, which the picture does not grow upwards for.
            guard row >= canvasHeader else { continue }
            let distance = abs(y - middle)
            if row < canvasHeight {
                guard distance <= canvasDistances[row] else { continue }
                canvasDistances[row] = distance
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
                canvasDistances.append(distance)
            }
        }
    }

    /// Keeps a frame that shows the content where the last placed one did,
    /// as the look of the area now: later frames are compared with it, and
    /// the picture ends with it (see `makeImage`).
    private mutating func keepLatestLook(_ frame: Frame, _ signatures: Signatures) {
        keep(frame, signatures)
        if canvasHeader == nil {
            // Until the first scroll the picture is just the area, the way
            // it looks now: say with the images that have finished loading.
            // Later frames show its upper half only further from the middle,
            // and would never bring the new look there.
            canvas = lastFrame
        }
    }

    private mutating func keep(_ frame: Frame, _ signatures: Signatures) {
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
        lastSignatures = signatures
    }

    // MARK: - Comparing rows

    /// Sums up each row of a frame as the mean brightness of equal blocks
    /// across it. Accelerate does the arithmetic, which keeps it fast even in
    /// a debug build, where loops written here run many times slower.
    struct Summarizer {
        let blockCount: Int
        let blockWidth: Int
        /// Multiplying a row of brightnesses by this gives its block means.
        private let blockMatrix: [Float]

        init(comparedWidth: Int) {
            blockCount = min(32, comparedWidth)
            blockWidth = comparedWidth / blockCount
            let usedWidth = blockCount * blockWidth
            var matrix = [Float](repeating: 0, count: usedWidth * blockCount)
            for x in 0..<usedWidth {
                matrix[x * blockCount + x / blockWidth] = 1 / Float(blockWidth)
            }
            blockMatrix = matrix
        }

        func signatures(of frame: Frame) -> Signatures {
            let usedWidth = blockCount * blockWidth
            let rows = frame.height
            var gray = [UInt8](repeating: 0, count: usedWidth * rows)
            gray.withUnsafeMutableBytes { gray in
                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: frame.pixels),
                    height: vImagePixelCount(rows),
                    width: vImagePixelCount(usedWidth),
                    rowBytes: frame.bytesPerRow
                )
                var destination = vImage_Buffer(
                    data: gray.baseAddress,
                    height: vImagePixelCount(rows),
                    width: vImagePixelCount(usedWidth),
                    rowBytes: usedWidth
                )
                // (blue + green + red) / 3, rounded; alpha does not count.
                let weights: [Int16] = [1, 1, 1, 0]
                vImageMatrixMultiply_ARGB8888ToPlanar8(
                    &source, &destination, weights, 3, nil, 1, vImage_Flags(kvImageNoFlags)
                )
            }
            var brightness = [Float](repeating: 0, count: gray.count)
            vDSP_vfltu8(gray, 1, &brightness, 1, vDSP_Length(gray.count))
            var values = [Float](repeating: 0, count: rows * blockCount)
            vDSP_mmul(
                brightness, 1, blockMatrix, 1, &values, 1,
                vDSP_Length(rows), vDSP_Length(blockCount), vDSP_Length(usedWidth)
            )
            return Signatures(rows: rows, length: blockCount, values: values)
        }
    }

    /// The block brightnesses of every row of a frame.
    struct Signatures {
        let rows: Int
        let length: Int
        let values: [Float]
        /// Rows that differ from the rows next to them. Unlike the rows of a
        /// blank or evenly shaded stretch, they can be told apart.
        let isDistinct: [Bool]
        /// Each row's values squared and added up.
        let squaredLengths: [Float]

        init(rows: Int, length: Int, values: [Float]) {
            self.rows = rows
            self.length = length
            self.values = values

            var isDistinct = [Bool](repeating: false, count: rows)
            let structure = 2 * ScrollStitcher.tolerance
            for step in 1...2 where rows > step {
                let differences = Self.distances(values, 0, values, step, count: rows - step, length: length)
                for (row, difference) in differences.enumerated() where difference > structure {
                    isDistinct[row] = true
                    isDistinct[row + step] = true
                }
            }
            self.isDistinct = isDistinct

            var squares = [Float](repeating: 0, count: values.count)
            vDSP_vsq(values, 1, &squares, 1, vDSP_Length(values.count))
            squaredLengths = Self.rowSums(squares, rows: rows, length: length)
        }

        /// Whether `row` here and `otherRow` of `other` show the same thing,
        /// give or take the noise.
        func matches(_ row: Int, _ other: Signatures, _ otherRow: Int) -> Bool {
            Self.distances(values, row, other.values, otherRow, count: 1, length: length)[0]
                <= ScrollStitcher.tolerance
        }

        /// How far each of `rows` here is from the row as far on in `other`,
        /// counting from `otherStart`.
        func distances(_ rows: Range<Int>, to other: Signatures, from otherStart: Int) -> [Float] {
            Self.distances(values, rows.lowerBound, other.values, otherStart, count: rows.count, length: length)
        }

        /// The largest difference between two rows' block brightnesses, for
        /// `count` pairs of rows at once: from `startA` in `a` and from
        /// `startB` in `b`.
        static func distances(
            _ a: [Float],
            _ startA: Int,
            _ b: [Float],
            _ startB: Int,
            count: Int,
            length: Int
        ) -> [Float] {
            guard count > 0 else { return [] }
            var differences = [Float](repeating: 0, count: count * length)
            a.withUnsafeBufferPointer { a in
                b.withUnsafeBufferPointer { b in
                    differences.withUnsafeMutableBufferPointer { differences in
                        let all = vDSP_Length(count * length)
                        vDSP_vsub(
                            b.baseAddress! + startB * length, 1,
                            a.baseAddress! + startA * length, 1,
                            differences.baseAddress!, 1, all
                        )
                        vDSP_vabs(differences.baseAddress!, 1, differences.baseAddress!, 1, all)
                    }
                }
            }
            return rowMaxima(differences, rows: count, length: length)
        }

        /// The largest value of each row, worked out a column at a time.
        private static func rowMaxima(_ values: [Float], rows: Int, length: Int) -> [Float] {
            var maxima = [Float](repeating: 0, count: rows)
            values.withUnsafeBufferPointer { values in
                maxima.withUnsafeMutableBufferPointer { maxima in
                    for column in 0..<length {
                        vDSP_vmax(
                            maxima.baseAddress!, 1, values.baseAddress! + column, vDSP_Stride(length),
                            maxima.baseAddress!, 1, vDSP_Length(rows)
                        )
                    }
                }
            }
            return maxima
        }

        private static func rowSums(_ values: [Float], rows: Int, length: Int) -> [Float] {
            var sums = [Float](repeating: 0, count: rows)
            values.withUnsafeBufferPointer { values in
                sums.withUnsafeMutableBufferPointer { sums in
                    for column in 0..<length {
                        vDSP_vadd(
                            sums.baseAddress!, 1, values.baseAddress! + column, vDSP_Stride(length),
                            sums.baseAddress!, 1, vDSP_Length(rows)
                        )
                    }
                }
            }
            return sums
        }
    }

    // MARK: - Finding the shift

    /// How far the content within `band` moved from `old` to `new`, in rows,
    /// or nil when that cannot be told. Positive means it moved up, that is,
    /// the user scrolled down.
    ///
    /// Distinct rows of `new` vote for the shifts at which `old` has a row
    /// that looks the same. The shift with the most votes wins, and ties go
    /// to the smaller shift, since frames come many times a second.
    static func shift(from old: Signatures, to new: Signatures, within band: Range<Int>) -> Int? {
        let span = band.count
        let length = new.length
        guard span > 0 else { return nil }
        let voters = evenlySpread(band.filter { new.isDistinct[$0] }, count: 96)
        guard voters.count >= minimumSupport else { return nil }

        // Every voter against every row of the band at once: the squared
        // distance |a - b|² is |a|² + |b|² - 2 a·b, and Accelerate works out
        // all the dot products a·b in one matrix product. Rows that are
        // close enough by that measure are checked properly.
        var oldRows = [Float](repeating: 0, count: length * span)
        old.values.withUnsafeBufferPointer { values in
            vDSP_mtrans(
                values.baseAddress! + band.lowerBound * length, 1, &oldRows, 1,
                vDSP_Length(length), vDSP_Length(span)
            )
        }
        var voterRows = [Float]()
        voterRows.reserveCapacity(voters.count * length)
        for row in voters {
            voterRows += new.values[(row * length)..<((row + 1) * length)]
        }
        var dotProducts = [Float](repeating: 0, count: voters.count * span)
        vDSP_mmul(
            voterRows, 1, oldRows, 1, &dotProducts, 1,
            vDSP_Length(voters.count), vDSP_Length(span), vDSP_Length(length)
        )
        let oldLengths = Array(old.squaredLengths[band])
        let closeEnough = Float(length) * tolerance * tolerance

        // votes[shift + span - 1] counts the rows that line up at `shift`.
        var votes = [Int](repeating: 0, count: 2 * span - 1)
        var squaredDistances = [Float](repeating: 0, count: span)
        for (index, row) in voters.enumerated() {
            var minusTwo: Float = -2
            var newLength = new.squaredLengths[row]
            dotProducts.withUnsafeBufferPointer { dotProducts in
                squaredDistances.withUnsafeMutableBufferPointer { distances in
                    vDSP_vsmsa(
                        dotProducts.baseAddress! + index * span, 1, &minusTwo, &newLength,
                        distances.baseAddress!, 1, vDSP_Length(span)
                    )
                    vDSP_vadd(distances.baseAddress!, 1, oldLengths, 1, distances.baseAddress!, 1, vDSP_Length(span))
                }
            }
            // The closest rows first, checked properly one by one.
            var matches: [Int] = []
            for _ in 0..<(2 * maximumRepeats + 2) {
                var smallest: Float = 0
                var position: vDSP_Length = 0
                vDSP_minvi(squaredDistances, 1, &smallest, &position, vDSP_Length(span))
                guard smallest <= closeEnough else { break }
                squaredDistances[Int(position)] = .infinity
                let oldRow = band.lowerBound + Int(position)
                if new.matches(row, old, oldRow) {
                    matches.append(oldRow)
                    if matches.count > maximumRepeats { break }
                }
            }
            guard matches.count <= maximumRepeats else { continue }
            for oldRow in matches {
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
        guard bestVotes > 0 else { return nil }

        // Every distinct row of `new` that should line up if `best` is right.
        let overlap = max(band.lowerBound, band.lowerBound - best)..<min(band.upperBound, band.upperBound - best)
        let distances = new.distances(overlap, to: old, from: overlap.lowerBound + best)
        var expected = 0
        var agreeing = 0
        for (row, distance) in zip(overlap, distances) where new.isDistinct[row] {
            expected += 1
            if distance <= tolerance {
                agreeing += 1
            }
        }
        guard
            agreeing >= minimumSupport,
            Double(agreeing) >= minimumAgreement * Double(expected)
        else { return nil }
        return best
    }

    /// At most `count` of `rows`, picked at even steps.
    private static func evenlySpread(_ rows: [Int], count: Int) -> [Int] {
        guard rows.count > count else { return rows }
        return (0..<count).map { rows[$0 * rows.count / count] }
    }

    /// The rows at the top and bottom of `new` that did not scroll along
    /// with the content, which moved by `shift` (not zero) since `old`.
    ///
    /// A row moved along when it matches the row `shift` further on in
    /// `old`, and not merely the same row as before: blank rows look alike
    /// either way, and count as not moving. That errs on the safe side,
    /// since rows taken for the header or footer are simply not copied this
    /// time. Rows that just scrolled into view have nothing to match yet;
    /// they lie between the last moving row and the footer, or between the
    /// header and the first.
    static func fixedRows(
        from old: Signatures,
        to new: Signatures,
        shift: Int
    ) -> (header: Int, footer: Int)? {
        let height = new.rows
        let rows = max(0, -shift)..<min(height, height - shift)
        let moved = new.distances(rows, to: old, from: rows.lowerBound + shift)
        let stayed = new.distances(rows, to: old, from: rows.lowerBound)
        var first: Int?
        var last: Int?
        for (index, row) in rows.enumerated() where moved[index] <= tolerance && stayed[index] > tolerance {
            first = first ?? row
            last = row
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
        of signatures: Signatures,
        unchangedAbove top: Int,
        below bottom: Int
    ) -> Int? {
        guard let header, let footer, header < height - footer else { return nil }
        var distinct = 0
        for row in header..<height - footer where (row < top || row >= bottom) && signatures.isDistinct[row] {
            distinct += 1
        }
        return distinct >= Self.minimumSupport ? 0 : nil
    }

    // MARK: - The picture

    /// The picture so far: the canvas, then the footer from the last frame.
    /// The pixels are read as BGRA, the layout ScreenCaptureKit delivers.
    func makeImage(colorSpace: CGColorSpace) -> CGImage? {
        guard !canvas.isEmpty else { return nil }
        let contentHeight = stitchedContentHeight
        let footerLength = (footer ?? 0) * rowLength
        // The picture may take a few hundred MB. Room for all of it at once
        // means each byte is copied only once, not again as it grows.
        var pixels = Data(capacity: contentHeight * rowLength + footerLength)
        pixels.append(canvas.prefix(contentHeight * rowLength))
        showLatestLook(in: &pixels, for: 0..<contentHeight)
        pixels.append(lastFrame.suffix(footerLength))
        return makeCGImage(from: pixels, colorSpace: colorSpace, shouldInterpolate: false)
    }

    /// The bottom rows of the stitched content so far, at most `maximumRows`
    /// tall, for previewing how far the picture reaches without copying the
    /// whole canvas.
    func makeTailImage(maximumRows: Int, colorSpace: CGColorSpace) -> CGImage? {
        guard maximumRows > 0, stitchedContentHeight > 0 else { return nil }
        let contentHeight = stitchedContentHeight
        let rowCount = min(contentHeight, maximumRows)
        let startRow = contentHeight - rowCount
        let startByte = startRow * rowLength
        let byteCount = rowCount * rowLength
        // Copy only the tail rows into an independent buffer so the preview
        // never retains the full canvas or forces copy-on-write on later rows.
        var pixels = canvas.withUnsafeBytes { bytes in
            Data(bytes: bytes.baseAddress! + startByte, count: byteCount)
        }
        showLatestLook(in: &pixels, for: startRow..<contentHeight)
        return makeCGImage(from: pixels, colorSpace: colorSpace, shouldInterpolate: true)
    }

    private func makeCGImage(
        from pixels: Data,
        colorSpace: CGColorSpace,
        shouldInterpolate: Bool
    ) -> CGImage? {
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
            shouldInterpolate: shouldInterpolate,
            intent: .defaultIntent
        )
    }

    /// Since the content last moved, the area may have changed in place: an
    /// image finished loading, or the scroll bar faded. The rows of the
    /// picture in `rows` that the latest frame shows at least as near the
    /// middle as their own look take the latest one, so that the picture
    /// ends as the area looks now, like its footer. Rows seen nearer the
    /// middle keep that look: by the edges, a bar may dim them.
    private func showLatestLook(in pixels: inout Data, for rows: Range<Int>) {
        let rowLength = rowLength
        let firstRow = max(canvasHeader ?? 0, rows.lowerBound)
        let contentRows = (header ?? 0)..<(height - (footer ?? 0))
        lastFrame.withUnsafeBytes { latest in
            pixels.withUnsafeMutableBytes { pixels in
                for y in contentRows {
                    let row = frameTop + y
                    guard
                        row >= firstRow, row < rows.upperBound,
                        abs(y - lastMiddle) <= canvasDistances[row]
                    else { continue }
                    pixels.baseAddress!
                        .advanced(by: (row - rows.lowerBound) * rowLength)
                        .copyMemory(from: latest.baseAddress! + y * rowLength, byteCount: rowLength)
                }
            }
        }
    }

    /// The canvas rows that go into the picture. Scrolling past the end of a
    /// page makes it spring back, and for a moment the frames show blank
    /// space below it. If the canvas ends in rows like that, all alike and
    /// each of one colour, below where the last frame's content ends, they
    /// are left out.
    private var pictureContentHeight: Int {
        guard let footer else { return canvasHeight }
        let lastContentEnd = max(frameTop + height - footer, canvasHeader ?? 0, 0)
        let tailHeight = canvasHeight - lastContentEnd
        // Taller than a frame, it cannot be such a moment.
        guard tailHeight > 0, tailHeight <= height else { return canvasHeight }

        // Most scroll-backs land on real content rather than blank spring-back
        // space, so checking the first row avoids summarizing the whole tail.
        let first = canvas.withUnsafeBytes { bytes in
            summarizer.signatures(
                of: Frame(
                    width: width,
                    height: 1,
                    bytesPerRow: rowLength,
                    pixels: bytes.baseAddress! + lastContentEnd * rowLength
                )
            )
        }
        guard first.values.max()! - first.values.min()! <= Self.tolerance else {
            return canvasHeight
        }
        guard tailHeight > 1 else { return lastContentEnd }

        let tail = canvas.withUnsafeBytes { bytes in
            summarizer.signatures(
                of: Frame(
                    width: width,
                    height: tailHeight - 1,
                    bytesPerRow: rowLength,
                    pixels: bytes.baseAddress! + (lastContentEnd + 1) * rowLength
                )
            )
        }
        let isBlank = (0..<(tailHeight - 1)).allSatisfy { tail.matches($0, first, 0) }
        return isBlank ? lastContentEnd : canvasHeight
    }
}
