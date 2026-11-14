import CoreGraphics
import Foundation
import Testing

@testable import Pashari

@MainActor
struct ScrollStitcherTests {
    private let width = 24
    private let frameHeight = 60

    @Test func theFirstFrameIsThePicture() {
        let document = Document.noise(width: width, height: 200)
        var stitcher = makeStitcher()

        #expect(stitcher.add(document.frame(at: 0, height: frameHeight)) == .started)

        #expect(rows(of: stitcher) == document.rows(0..<frameHeight))
    }

    @Test func framesScrolledDownAreJoinedInOrder() {
        let document = Document.noise(width: width, height: 400)
        var stitcher = makeStitcher()

        var outcomes: [ScrollStitcher.Outcome] = []
        for offset in [0, 1, 11, 40, 85, 130] {
            outcomes.append(stitcher.add(document.frame(at: offset, height: frameHeight)))
        }

        #expect(outcomes == [.started, .scrolled(1), .scrolled(10), .scrolled(29), .scrolled(45), .scrolled(45)])
        #expect(rows(of: stitcher) == document.rows(0..<(130 + frameHeight)))
    }

    @Test func anUnchangedFrameAddsNothing() {
        let document = Document.noise(width: width, height: 200)
        var stitcher = makeStitcher()
        _ = stitcher.add(document.frame(at: 0, height: frameHeight))

        #expect(stitcher.add(document.frame(at: 0, height: frameHeight)) == .unchanged)
        #expect(stitcher.pictureHeight == frameHeight)
    }

    @Test func scrollingBackUpAndDownAgainAddsEachRowOnce() {
        let document = Document.noise(width: width, height: 400)
        var stitcher = makeStitcher()

        for offset in [0, 30, 10, 0, 45, 90] {
            _ = stitcher.add(document.frame(at: offset, height: frameHeight))
        }

        #expect(rows(of: stitcher) == document.rows(0..<(90 + frameHeight)))
    }

    @Test func aFixedHeaderAndFooterAppearOnceAtTheEnds() {
        let document = Document.noise(width: width, height: 400, seed: 1)
        let header = Document.noise(width: width, height: 8, seed: 2)
        let footer = Document.noise(width: width, height: 5, seed: 3)
        var stitcher = makeStitcher()

        for offset in [0, 20, 45, 75] {
            let frame = document.frame(at: offset, height: frameHeight, header: header, footer: footer)
            _ = stitcher.add(frame)
        }

        // The content under the header and footer is hidden in every frame.
        let picture = rows(of: stitcher)
        let contentEnd = 75 + frameHeight - 5
        #expect(picture.count == 75 + frameHeight)
        #expect(Array(picture[0..<8]) == header.rows(0..<8))
        #expect(Array(picture[8..<contentEnd]) == document.rows(8..<contentEnd))
        #expect(Array(picture[contentEnd...]) == footer.rows(0..<5))
    }

    @Test func blankRowsOnlyCountAroundTheRowsThatShowWhatMoved() {
        // Mostly white, like a page of text with space between the lines.
        let document = Document.lines(width: width, height: 400)
        var stitcher = makeStitcher()

        for offset in [0, 7, 19, 33, 64, 100] {
            #expect(stitcher.add(document.frame(at: offset, height: frameHeight)) != .lost)
        }

        #expect(rows(of: stitcher) == document.rows(0..<(100 + frameHeight)))
    }

    @Test func aScrollBarAtTheRightEdgeDoesNotHideTheShift() {
        let document = Document.noise(width: width, height: 400)
        var stitcher = makeStitcher(ignoringRightColumns: 4)

        for (index, offset) in [0, 25, 50].enumerated() {
            var frame = document.slice(at: offset, height: frameHeight)
            // The scroll bar's thumb moves down while the content moves up.
            frame.paint(columns: (width - 3)..<width, rows: (index * 15)..<(index * 15 + 20), value: 40)
            _ = stitcher.add(frame)
        }

        #expect(stitcher.pictureHeight == 50 + frameHeight)
    }

    @Test func aJumpTooFarToPlaceIsLeftOutUntilTheContentComesBack() {
        let document = Document.noise(width: width, height: 400)
        var stitcher = makeStitcher()
        _ = stitcher.add(document.frame(at: 0, height: frameHeight))
        _ = stitcher.add(document.frame(at: 20, height: frameHeight))

        // Further than the area is tall: nothing lines up with the last frame.
        #expect(stitcher.add(document.frame(at: 120, height: frameHeight)) == .lost)
        #expect(stitcher.pictureHeight == 20 + frameHeight)

        // The user scrolls back up, to where the last placed frame overlaps.
        #expect(stitcher.add(document.frame(at: 60, height: frameHeight)) == .scrolled(40))
        #expect(rows(of: stitcher) == document.rows(0..<(60 + frameHeight)))
    }

    @Test func aSmallChangeThatCannotBePlacedIsIgnored() {
        let document = Document.noise(width: width, height: 400)
        var stitcher = makeStitcher()
        _ = stitcher.add(document.frame(at: 0, height: frameHeight))

        // A blinking text cursor: a few rows change, nothing moves.
        var frame = document.slice(at: 0, height: frameHeight)
        frame.paint(columns: 5..<7, rows: 30..<36, value: 0)

        #expect(stitcher.add(frame) == .ignored)
        #expect(rows(of: stitcher) == document.rows(0..<frameHeight))
    }

    @Test func contentThatChangesInPlaceShowsItsNewLook() {
        let document = Document.noise(width: width, height: 400, seed: 4)
        let header = Document.noise(width: width, height: 4, seed: 5)
        var stitcher = makeStitcher()
        _ = stitcher.add(document.frame(at: 0, height: frameHeight, header: header))
        _ = stitcher.add(document.frame(at: 30, height: frameHeight, header: header))

        // An image finishes loading over most of the frame.
        var frame = document.slice(at: 30, height: frameHeight, header: header)
        frame.paint(columns: 0..<width, rows: 10..<50, value: 200)

        #expect(stitcher.add(frame) == .changedInPlace)
        let picture = rows(of: stitcher)
        #expect(picture.count == 30 + frameHeight)
        #expect(picture[30 + 10] == [UInt8](repeating: 200, count: width * 4))
        #expect(picture[30 + 49] == [UInt8](repeating: 200, count: width * 4))
        #expect(picture[30 + 50] == document.rows(80..<81)[0])
    }

    @Test func thePictureStopsGrowingAtTheMaximumHeight() {
        let document = Document.noise(width: width, height: 400)
        var stitcher = ScrollStitcher(width: width, height: frameHeight, maximumHeight: 100)
        _ = stitcher.add(document.frame(at: 0, height: frameHeight))
        _ = stitcher.add(document.frame(at: 30, height: frameHeight))

        #expect(stitcher.add(document.frame(at: 60, height: frameHeight)) == .full)
        #expect(stitcher.add(document.frame(at: 70, height: frameHeight)) == .full)
        #expect(rows(of: stitcher) == document.rows(0..<100))
    }

    @Test func thePictureIsABGRAImage() throws {
        // Blue, green, red, alpha: opaque red.
        let red: [UInt8] = [0, 0, 255, 255]
        let pixels = Array(repeating: red, count: 4 * 3).flatMap { $0 }
        var stitcher = ScrollStitcher(width: 4, height: 3, maximumHeight: 10)
        _ = pixels.withUnsafeBytes { bytes in
            stitcher.add(ScrollStitcher.Frame(width: 4, height: 3, bytesPerRow: 16, pixels: bytes.baseAddress!))
        }

        let image = try #require(stitcher.makeImage(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))

        #expect(image.width == 4)
        #expect(image.height == 3)
        #expect(TestImages.pixel(of: image, x: 2, y: 1) == .red)
    }

    @Test func framesWithPaddedRowsAreReadCorrectly() {
        let document = Document.noise(width: width, height: 200)
        var stitcher = makeStitcher()

        for offset in [0, 17] {
            let slice = document.slice(at: offset, height: frameHeight)
            // Each row followed by 8 bytes of padding, as video buffers often are.
            let bytesPerRow = width * 4 + 8
            var padded = [UInt8](repeating: 0xEE, count: bytesPerRow * frameHeight)
            for y in 0..<frameHeight {
                padded.replaceSubrange(y * bytesPerRow..<(y * bytesPerRow + width * 4), with: slice.rows[y])
            }
            _ = padded.withUnsafeBytes { bytes in
                stitcher.add(
                    ScrollStitcher.Frame(
                        width: width,
                        height: frameHeight,
                        bytesPerRow: bytesPerRow,
                        pixels: bytes.baseAddress!
                    )
                )
            }
        }

        #expect(rows(of: stitcher) == document.rows(0..<(17 + frameHeight)))
    }

    // MARK: - Helpers

    private func makeStitcher(ignoringRightColumns: Int = 0) -> ScrollStitcher {
        ScrollStitcher(
            width: width,
            height: frameHeight,
            maximumHeight: 10_000,
            ignoringRightColumns: ignoringRightColumns
        )
    }

    /// The picture's rows, each as its bytes.
    private func rows(of stitcher: ScrollStitcher) -> [[UInt8]] {
        guard let image = stitcher.makeImage(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return [] }
        let data: Data = image.dataProvider!.data! as Data
        let rowLength = image.width * 4
        return (0..<image.height).map { y in
            let start = y * image.bytesPerRow
            return [UInt8](data[start..<(start + rowLength)])
        }
    }
}

/// A tall picture to scroll through, 4 bytes per pixel.
private struct Document {
    var rows: [[UInt8]]

    var width: Int { rows[0].count / 4 }

    /// Every pixel different from its neighbours, so every row is unique.
    static func noise(width: Int, height: Int, seed: UInt64 = 0) -> Document {
        var generator = Generator(seed: seed)
        return Document(rows: (0..<height).map { _ in
            (0..<width * 4).map { _ in generator.next() }
        })
    }

    /// Short runs of noise between longer runs of white rows.
    static func lines(width: Int, height: Int) -> Document {
        var generator = Generator(seed: 7)
        return Document(rows: (0..<height).map { y in
            y % 12 < 5
                ? (0..<width * 4).map { _ in generator.next() }
                : [UInt8](repeating: 255, count: width * 4)
        })
    }

    func rows(_ range: Range<Int>) -> [[UInt8]] {
        Array(rows[range])
    }

    /// What the area shows when scrolled down by `offset` rows, under a
    /// fixed header and over a fixed footer if given.
    func slice(at offset: Int, height: Int, header: Document? = nil, footer: Document? = nil) -> Slice {
        var slice = Slice(rows: Array(rows[offset..<(offset + height)]))
        if let header {
            slice.rows.replaceSubrange(0..<header.rows.count, with: header.rows)
        }
        if let footer {
            slice.rows.replaceSubrange((height - footer.rows.count)..<height, with: footer.rows)
        }
        return slice
    }

    func frame(at offset: Int, height: Int, header: Document? = nil, footer: Document? = nil) -> Slice {
        slice(at: offset, height: height, header: header, footer: footer)
    }

    struct Slice {
        var rows: [[UInt8]]

        mutating func paint(columns: Range<Int>, rows rowRange: Range<Int>, value: UInt8) {
            for y in rowRange {
                for x in columns {
                    rows[y].replaceSubrange((x * 4)..<(x * 4 + 4), with: [value, value, value, value])
                }
            }
        }

        func withFrame<Result>(_ body: (ScrollStitcher.Frame) -> Result) -> Result {
            let bytes = rows.flatMap { $0 }
            return bytes.withUnsafeBytes { buffer in
                body(
                    ScrollStitcher.Frame(
                        width: rows[0].count / 4,
                        height: rows.count,
                        bytesPerRow: rows[0].count,
                        pixels: buffer.baseAddress!
                    )
                )
            }
        }
    }

    private struct Generator {
        var state: UInt64

        init(seed: UInt64) {
            state = seed &+ 0x9E37_79B9_7F4A_7C15
        }

        mutating func next() -> UInt8 {
            // SplitMix64: plenty random for test pictures, and repeatable.
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return UInt8(truncatingIfNeeded: z ^ (z >> 31))
        }
    }
}

private extension ScrollStitcher {
    mutating func add(_ slice: Document.Slice) -> Outcome {
        slice.withFrame { add($0) }
    }
}
