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

        #expect(isClose(rows(of: stitcher), document.rows(0..<frameHeight)))
    }

    @Test func framesScrolledDownAreJoinedInOrder() {
        let document = Document.noise(width: width, height: 400)
        var stitcher = makeStitcher()

        var outcomes: [ScrollStitcher.Outcome] = []
        for offset in [0, 1, 11, 40, 85, 130] {
            outcomes.append(stitcher.add(document.frame(at: offset, height: frameHeight)))
        }

        #expect(outcomes == [.started, .scrolled(1), .scrolled(10), .scrolled(29), .scrolled(45), .scrolled(45)])
        #expect(isClose(rows(of: stitcher), document.rows(0..<(130 + frameHeight))))
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

        #expect(isClose(rows(of: stitcher), document.rows(0..<(90 + frameHeight))))
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
        #expect(isClose(Array(picture[0..<8]), header.rows(0..<8)))
        #expect(isClose(Array(picture[8..<contentEnd]), document.rows(8..<contentEnd)))
        #expect(isClose(Array(picture[contentEnd...]), footer.rows(0..<5)))
    }

    @Test func blankRowsOnlyCountAroundTheRowsThatShowWhatMoved() {
        // Mostly white, like a page of text with space between the lines.
        let document = Document.lines(width: width, height: 400)
        var stitcher = makeStitcher()

        for offset in [0, 7, 19, 33, 64, 100] {
            #expect(stitcher.add(document.frame(at: offset, height: frameHeight)) != .lost)
        }

        #expect(isClose(rows(of: stitcher), document.rows(0..<(100 + frameHeight))))
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

    @Test func aScrollBarThatFadesOnceTheScrollingStopsLeavesNoTrace() {
        let document = Document.noise(width: width, height: 400, seed: 16)
        var stitcher = makeStitcher(ignoringRightColumns: 4)
        _ = stitcher.add(document.frame(at: 0, height: frameHeight))

        // While the page scrolls, its scroll bar shows over its right edge,
        // low in the area, as near the end of a page.
        for (offset, thumbTop) in [(20, 40), (40, 42)] {
            var frame = document.slice(at: offset, height: frameHeight)
            frame.paint(columns: (width - 3)..<width, rows: thumbTop..<(thumbTop + 14), value: 40)
            _ = stitcher.add(frame)
        }
        // Then it fades, which changes only columns the frames are not
        // compared by.
        #expect(stitcher.add(document.frame(at: 40, height: frameHeight)) == .unchanged)

        #expect(isClose(rows(of: stitcher), document.rows(0..<(40 + frameHeight))))
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
        #expect(isClose(rows(of: stitcher), document.rows(0..<(60 + frameHeight))))
    }

    @Test func somethingPlayingBeforeTheFirstScrollIsNotTakenForAJump() {
        let document = Document.noise(width: width, height: 400, seed: 17)
        var stitcher = makeStitcher()
        _ = stitcher.add(document.frame(at: 0, height: frameHeight))

        // A video plays over half of the area before the user scrolls.
        var playing = document
        playing.rows.replaceSubrange(15..<45, with: Document.noise(width: width, height: 30, seed: 18).rows)
        #expect(stitcher.add(playing.frame(at: 0, height: frameHeight)) == .ignored)

        // A first scroll further than the area is tall still is one.
        #expect(stitcher.add(document.frame(at: 100, height: frameHeight)) == .lost)
    }

    @Test func aSmallChangeThatCannotBePlacedIsIgnored() {
        let document = Document.noise(width: width, height: 400)
        var stitcher = makeStitcher()
        _ = stitcher.add(document.frame(at: 0, height: frameHeight))

        // A blinking text cursor: a few rows change, nothing moves.
        var frame = document.slice(at: 0, height: frameHeight)
        frame.paint(columns: 5..<7, rows: 30..<36, value: 0)

        #expect(stitcher.add(frame) == .ignored)
        #expect(isClose(rows(of: stitcher), document.rows(0..<frameHeight)))
    }

    @Test func contentThatChangesInPlaceShowsItsNewLook() {
        let document = Document.noise(width: width, height: 400, seed: 4)
        let header = Document.noise(width: width, height: 4, seed: 5)
        var stitcher = makeStitcher()
        _ = stitcher.add(document.frame(at: 0, height: frameHeight, header: header))
        _ = stitcher.add(document.frame(at: 30, height: frameHeight, header: header))

        // An image finishes loading low in the area. Should the recording
        // end now, the picture ends as the area looks now.
        var loaded = document
        loaded.paint(columns: 0..<width, rows: 70..<85, value: 200)

        #expect(stitcher.add(loaded.frame(at: 30, height: frameHeight, header: header)) == .changedInPlace)
        #expect(isClose(Array(rows(of: stitcher)[70..<85]), loaded.rows(70..<85)))

        // Then it scrolls up past the middle.
        for offset in [35, 45, 55] {
            _ = stitcher.add(loaded.frame(at: offset, height: frameHeight, header: header))
        }
        let picture = rows(of: stitcher)
        #expect(picture.count == 55 + frameHeight)
        #expect(isClose(Array(picture[4..<70]), document.rows(4..<70)))
        #expect(isClose(Array(picture[70..<85]), loaded.rows(70..<85)))
    }

    @Test func whatChangedInPlaceBeforeTheFirstScrollShowsInThePicture() {
        let document = Document.noise(width: width, height: 400, seed: 13)
        var stitcher = makeStitcher()
        _ = stitcher.add(document.frame(at: 0, height: frameHeight))

        // Two images finish loading before the user starts scrolling, one
        // of them high in the area: no later frame shows it nearer the
        // middle.
        var loaded = document
        loaded.paint(columns: 0..<width, rows: 10..<16, value: 200)
        loaded.paint(columns: 0..<width, rows: 40..<46, value: 90)

        #expect(stitcher.add(loaded.frame(at: 0, height: frameHeight)) == .changedInPlace)
        #expect(isClose(rows(of: stitcher), loaded.rows(0..<frameHeight)))

        for offset in [15, 30] {
            _ = stitcher.add(loaded.frame(at: offset, height: frameHeight))
        }
        #expect(isClose(rows(of: stitcher), loaded.rows(0..<(30 + frameHeight))))
    }

    @Test func aSeeThroughHeaderAndFooterStayOutOfTheContent() {
        let document = Document.noise(width: width, height: 400, seed: 8)
        var stitcher = makeStitcher()

        for offset in [0, 12, 30, 51, 80] {
            // Bars that show the content under them, dimmed, as macOS's
            // toolbars do: their rows change with every scroll.
            var frame = document.slice(at: offset, height: frameHeight)
            frame.dim(rows: 0..<6)
            frame.dim(rows: (frameHeight - 4)..<frameHeight)
            _ = stitcher.add(frame)
        }

        let picture = rows(of: stitcher)
        var first = document.slice(at: 0, height: frameHeight)
        first.dim(rows: 0..<6)
        var last = document.slice(at: 80, height: frameHeight)
        last.dim(rows: (frameHeight - 4)..<frameHeight)
        #expect(picture.count == 80 + frameHeight)
        #expect(isClose(Array(picture[0..<6]), Array(first.rows[0..<6])))
        #expect(isClose(Array(picture[6..<(80 + frameHeight - 4)]), document.rows(6..<(80 + frameHeight - 4))))
        #expect(isClose(Array(picture[(80 + frameHeight - 4)...]), Array(last.rows[(frameHeight - 4)...])))
    }

    @Test func seeThroughBarsTallerThanEachScrollStayOutOfTheContent() {
        let document = Document.noise(width: width, height: 400, seed: 12)
        var stitcher = makeStitcher()

        // Under a bar that only dims, rows a few apart still look alike
        // after a small scroll, so the dimmed rows seem to move along with
        // the content.
        for offset in stride(from: 0, through: 40, by: 4) {
            var frame = document.slice(at: offset, height: frameHeight)
            frame.dim(rows: 0..<12)
            frame.dim(rows: (frameHeight - 8)..<frameHeight)
            _ = stitcher.add(frame)
        }

        let picture = rows(of: stitcher)
        let contentEnd = 40 + frameHeight - 8
        var first = document.slice(at: 0, height: frameHeight)
        first.dim(rows: 0..<12)
        var last = document.slice(at: 40, height: frameHeight)
        last.dim(rows: (frameHeight - 8)..<frameHeight)
        #expect(picture.count == 40 + frameHeight)
        #expect(isClose(Array(picture[0..<12]), Array(first.rows[0..<12])))
        #expect(isClose(Array(picture[12..<contentEnd]), document.rows(12..<contentEnd)))
        #expect(isClose(Array(picture[contentEnd...]), Array(last.rows[(frameHeight - 8)...])))
    }

    @Test func aHeaderThatSticksOnlyLaterIsNotCopiedIntoThePicture() {
        let document = Document.noise(width: width, height: 400, seed: 9)
        let header = Document.noise(width: width, height: 10, seed: 10)
        var stitcher = makeStitcher()

        for offset in [0, 20, 40] {
            _ = stitcher.add(document.frame(at: offset, height: frameHeight))
        }
        // A bar slides in over the top, then stays while the page scrolls.
        #expect(stitcher.add(document.frame(at: 40, height: frameHeight, header: header)) == .changedInPlace)
        for offset in [55, 70, 90] {
            _ = stitcher.add(document.frame(at: offset, height: frameHeight, header: header))
        }

        #expect(isClose(rows(of: stitcher), document.rows(0..<(90 + frameHeight))))
    }

    @Test func aFooterThatAppearsLaterLeavesTheContentSeenBeforeIt() {
        let document = Document.noise(width: width, height: 400, seed: 14)
        let footer = Document.noise(width: width, height: 20, seed: 15)
        var stitcher = makeStitcher()

        for offset in [0, 20, 40] {
            _ = stitcher.add(document.frame(at: offset, height: frameHeight))
        }
        // A bar slides in over the bottom and stays, while the page scrolls
        // on by less than the bar is tall.
        #expect(stitcher.add(document.frame(at: 40, height: frameHeight, footer: footer)) == .changedInPlace)
        _ = stitcher.add(document.frame(at: 45, height: frameHeight, footer: footer))

        // What came into view before the bar did, then the bar, once.
        let seen = 40 + frameHeight
        var picture = rows(of: stitcher)
        #expect(picture.count == seen + 20)
        #expect(isClose(Array(picture[0..<seen]), document.rows(0..<seen)))
        #expect(isClose(Array(picture[seen...]), footer.rows(0..<20)))

        for offset in [60, 80] {
            _ = stitcher.add(document.frame(at: offset, height: frameHeight, footer: footer))
        }
        let contentEnd = 80 + frameHeight - 20
        picture = rows(of: stitcher)
        #expect(picture.count == 80 + frameHeight)
        #expect(isClose(Array(picture[0..<contentEnd]), document.rows(0..<contentEnd)))
        #expect(isClose(Array(picture[contentEnd...]), footer.rows(0..<20)))
    }

    @Test func blankSpaceShownWhileSpringingBackFromTheEndIsLeftOut() {
        let document = Document.noise(width: width, height: 200, seed: 11)
        let end = 200 - frameHeight
        var stitcher = makeStitcher()

        for offset in [0, 50, 100, end] {
            _ = stitcher.add(document.frame(at: offset, height: frameHeight))
        }
        // Past the end, blank space shows below the page, then it springs back.
        for overshoot in [10, 20, 12] {
            var frame = document.slice(at: end + overshoot, height: frameHeight - overshoot)
            frame.rows += Array(repeating: [UInt8](repeating: 236, count: width * 4), count: overshoot)
            _ = stitcher.add(frame)
        }
        _ = stitcher.add(document.frame(at: end, height: frameHeight))

        #expect(isClose(rows(of: stitcher), document.rows(0..<200)))
    }

    @Test func thePictureStopsGrowingAtTheMaximumHeight() {
        let document = Document.noise(width: width, height: 400)
        var stitcher = ScrollStitcher(width: width, height: frameHeight, maximumHeight: 100)
        _ = stitcher.add(document.frame(at: 0, height: frameHeight))
        _ = stitcher.add(document.frame(at: 30, height: frameHeight))

        #expect(stitcher.add(document.frame(at: 60, height: frameHeight)) == .full)
        #expect(stitcher.add(document.frame(at: 70, height: frameHeight)) == .full)
        #expect(isClose(rows(of: stitcher), document.rows(0..<100)))
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

        #expect(isClose(rows(of: stitcher), document.rows(0..<(17 + frameHeight))))
    }

    @Test func tailImageReturnsOnlyTheBottomRowsOfTheStitchedContent() throws {
        let document = Document.noise(width: width, height: 400, seed: 20)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var stitcher = makeStitcher()

        #expect(stitcher.makeTailImage(maximumRows: 25, colorSpace: colorSpace) == nil)

        _ = stitcher.add(document.frame(at: 0, height: frameHeight))
        #expect(stitcher.makeTailImage(maximumRows: 0, colorSpace: colorSpace) == nil)
        let wholeFirst = try #require(stitcher.makeTailImage(maximumRows: 100, colorSpace: colorSpace))
        #expect(isClose(rows(of: wholeFirst), document.rows(0..<frameHeight)))

        _ = stitcher.add(document.frame(at: 20, height: frameHeight))
        let firstTail = try #require(stitcher.makeTailImage(maximumRows: 25, colorSpace: colorSpace))
        let expectedFirstTail = document.rows((20 + frameHeight - 25)..<(20 + frameHeight))
        #expect(isClose(rows(of: firstTail), expectedFirstTail))

        // Appending more frames leaves an earlier tail image untouched.
        _ = stitcher.add(document.frame(at: 50, height: frameHeight))
        #expect(isClose(rows(of: firstTail), expectedFirstTail))
        let nextTail = try #require(stitcher.makeTailImage(maximumRows: 25, colorSpace: colorSpace))
        #expect(isClose(rows(of: nextTail), document.rows((50 + frameHeight - 25)..<(50 + frameHeight))))
    }

    @Test func tailImageLeavesOutAFixedFooterOnceScrollingBegins() throws {
        let document = Document.noise(width: width, height: 400, seed: 21)
        let header = Document.noise(width: width, height: 8, seed: 22)
        let footer = Document.noise(width: width, height: 5, seed: 23)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var stitcher = makeStitcher()

        for offset in [0, 20, 45] {
            _ = stitcher.add(document.frame(at: offset, height: frameHeight, header: header, footer: footer))
        }

        let contentEnd = 45 + frameHeight - 5
        let tail = try #require(stitcher.makeTailImage(maximumRows: 25, colorSpace: colorSpace))
        #expect(isClose(rows(of: tail), document.rows((contentEnd - 25)..<contentEnd)))
    }

    @Test func tailImageLeavesOutBlankSpringBackSpace() throws {
        let document = Document.noise(width: width, height: 200, seed: 24)
        let end = 200 - frameHeight
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var stitcher = makeStitcher()

        for offset in [0, 50, 100, end] {
            _ = stitcher.add(document.frame(at: offset, height: frameHeight))
        }
        for overshoot in [10, 20] {
            var frame = document.slice(at: end + overshoot, height: frameHeight - overshoot)
            frame.rows += Array(repeating: [UInt8](repeating: 236, count: width * 4), count: overshoot)
            _ = stitcher.add(frame)
        }
        _ = stitcher.add(document.frame(at: end, height: frameHeight))

        let tail = try #require(stitcher.makeTailImage(maximumRows: 25, colorSpace: colorSpace))
        #expect(isClose(rows(of: tail), document.rows(175..<200)))
    }

    @Test func tailImageKeepsTheLastStitchedEndWhileLostAndUpdatesOnRecovery() throws {
        let document = Document.noise(width: width, height: 400, seed: 25)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var stitcher = makeStitcher()
        _ = stitcher.add(document.frame(at: 0, height: frameHeight))
        _ = stitcher.add(document.frame(at: 20, height: frameHeight))

        #expect(stitcher.add(document.frame(at: 120, height: frameHeight)) == .lost)
        let lostTail = try #require(stitcher.makeTailImage(maximumRows: 25, colorSpace: colorSpace))
        #expect(isClose(rows(of: lostTail), document.rows((20 + frameHeight - 25)..<(20 + frameHeight))))

        #expect(stitcher.add(document.frame(at: 60, height: frameHeight)) == .scrolled(40))
        let resumedTail = try #require(stitcher.makeTailImage(maximumRows: 25, colorSpace: colorSpace))
        #expect(isClose(rows(of: resumedTail), document.rows((60 + frameHeight - 25)..<(60 + frameHeight))))
    }

    @Test func tailImageShowsInPlaceChangesInTheLatestFrame() throws {
        let document = Document.noise(width: width, height: 400, seed: 26)
        let header = Document.noise(width: width, height: 4, seed: 27)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var stitcher = makeStitcher()
        _ = stitcher.add(document.frame(at: 0, height: frameHeight, header: header))
        _ = stitcher.add(document.frame(at: 30, height: frameHeight, header: header))

        var loaded = document
        loaded.paint(columns: 0..<width, rows: 70..<85, value: 200)
        #expect(stitcher.add(loaded.frame(at: 30, height: frameHeight, header: header)) == .changedInPlace)
        #expect(stitcher.lastFrameOverlapsTail(maximumRows: 25))

        let tail = try #require(stitcher.makeTailImage(maximumRows: 25, colorSpace: colorSpace))
        #expect(isClose(Array(rows(of: tail)[5..<20]), loaded.rows(70..<85)))
    }

    @Test func tailImageClearsAFadingScrollBarOnAnUnchangedFrame() throws {
        let document = Document.noise(width: width, height: 400, seed: 29)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var stitcher = makeStitcher(ignoringRightColumns: 4)
        _ = stitcher.add(document.frame(at: 0, height: frameHeight))

        for (offset, thumbTop) in [(20, 40), (40, 42)] {
            var frame = document.slice(at: offset, height: frameHeight)
            frame.paint(columns: (width - 3)..<width, rows: thumbTop..<(thumbTop + 14), value: 40)
            _ = stitcher.add(frame)
        }
        #expect(stitcher.add(document.frame(at: 40, height: frameHeight)) == .unchanged)
        #expect(stitcher.lastFrameOverlapsTail(maximumRows: 25))

        let tail = try #require(stitcher.makeTailImage(maximumRows: 25, colorSpace: colorSpace))
        #expect(isClose(rows(of: tail), document.rows((40 + frameHeight - 25)..<(40 + frameHeight))))
    }

    @Test func lastFrameOverlapsTailDetectsRecoveryScrollsAtSameHeight() throws {
        let document = Document.noise(width: width, height: 400, seed: 28)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var stitcher = makeStitcher()
        _ = stitcher.add(document.frame(at: 0, height: frameHeight))
        _ = stitcher.add(document.frame(at: 30, height: frameHeight))

        #expect(stitcher.add(document.frame(at: 150, height: frameHeight)) == .lost)

        // Scrolling slightly back up to recover leaves pictureHeight at 90,
        // while overlapping the tail rows and updating pixels nearer the middle.
        var updated = document
        updated.paint(columns: 0..<width, rows: 48..<55, value: 210)
        #expect(stitcher.add(updated.frame(at: 20, height: frameHeight)) == .scrolled(-10))
        #expect(stitcher.pictureHeight == 90)
        #expect(stitcher.lastFrameOverlapsTail(maximumRows: 45))

        let tail = try #require(stitcher.makeTailImage(maximumRows: 45, colorSpace: colorSpace))
        #expect(isClose(Array(rows(of: tail)[3..<10]), updated.rows(48..<55)))

        // Scrolling far above the tail does not overlap it.
        _ = stitcher.add(document.frame(at: 60, height: frameHeight))
        _ = stitcher.add(document.frame(at: 100, height: frameHeight))
        _ = stitcher.add(document.frame(at: 70, height: frameHeight))
        _ = stitcher.add(document.frame(at: 40, height: frameHeight))
        _ = stitcher.add(document.frame(at: 0, height: frameHeight))
        #expect(!stitcher.lastFrameOverlapsTail(maximumRows: 45))
    }

    @Test func lastFrameOverlapsTailIsFalseWhenScrolledAboveTheHeader() {
        let document = Document.noise(width: width, height: 400, seed: 30)
        let header = Document.noise(width: width, height: 10, seed: 31)
        var stitcher = makeStitcher()
        // Start mid-document so scrolling up can push the frame above canvasHeader.
        _ = stitcher.add(document.frame(at: 120, height: frameHeight, header: header))
        _ = stitcher.add(document.frame(at: 90, height: frameHeight, header: header))
        _ = stitcher.add(document.frame(at: 60, height: frameHeight, header: header))

        #expect(!stitcher.lastFrameOverlapsTail(maximumRows: frameHeight))
    }

    @Test func progressTrackerCoalescesIdleFramesAndKeepsTailAlignedWithMakeImage() throws {
        let document = Document.noise(width: width, height: 400, seed: 32)
        let header = Document.noise(width: width, height: 4, seed: 33)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var stitcher = makeStitcher()
        var tracker = ScrollRecorder.ProgressTracker(previewTailRows: 25)

        func step(_ slice: Document.Slice) -> ScrollRecorder.Progress? {
            let outcome = stitcher.add(slice)
            return tracker.update(after: outcome, stitcher: stitcher, colorSpace: colorSpace)
        }

        let started = try #require(step(document.frame(at: 0, height: frameHeight, header: header)))
        #expect(started.preview != nil)

        // Idle `.unchanged` frames must not allocate a new preview or emit progress.
        #expect(step(document.frame(at: 0, height: frameHeight, header: header)) == nil)

        // Grow the picture, then apply an in-place change in the tail.
        for offset in [40, 80] {
            _ = step(document.frame(at: offset, height: frameHeight, header: header))
        }
        var loaded = document
        loaded.paint(columns: 0..<width, rows: 120..<132, value: 215)
        let inPlace = try #require(step(loaded.frame(at: 80, height: frameHeight, header: header)))
        let inPlaceTail = try #require(inPlace.preview)
        #expect(isClose(Array(rows(of: inPlaceTail)[5..<17]), loaded.rows(120..<132)))

        // Jump upward past the tail: `lastFrame` no longer overlays the tail, so
        // the preview refreshes once to match `makeImage` without the in-place overlay.
        let scrolledUp = try #require(step(document.frame(at: 40, height: frameHeight, header: header)))
        let afterLeaveTail = try #require(scrolledUp.preview)
        #expect(afterLeaveTail !== inPlaceTail)
        #expect(isClose(rows(of: afterLeaveTail), Array(rows(of: stitcher).suffix(25))))

        // Further scrolls above the tail do not rebuild the preview.
        #expect(step(document.frame(at: 10, height: frameHeight, header: header)) == nil)

        // Lost keeps the exact preview instance until recovery.
        let lost = try #require(step(document.frame(at: 200, height: frameHeight, header: header)))
        #expect(lost.isLost)
        #expect(lost.preview === afterLeaveTail)
    }

    @Test func progressTrackerUpdatesOnFirstFullAndSkipsRepeatedFull() throws {
        let document = Document.noise(width: width, height: 400, seed: 34)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var stitcher = ScrollStitcher(width: width, height: frameHeight, maximumHeight: 90)
        var tracker = ScrollRecorder.ProgressTracker(previewTailRows: 25)

        func step(_ slice: Document.Slice) -> ScrollRecorder.Progress? {
            let outcome = stitcher.add(slice)
            return tracker.update(after: outcome, stitcher: stitcher, colorSpace: colorSpace)
        }

        _ = step(document.frame(at: 0, height: frameHeight))
        let atLimit = try #require(step(document.frame(at: 30, height: frameHeight)))
        #expect(!atLimit.isFull)

        var updated = document
        updated.paint(columns: 0..<width, rows: 68..<76, value: 220)
        let firstFull = try #require(step(updated.frame(at: 40, height: frameHeight)))
        #expect(firstFull.isFull)
        let fullTail = try #require(firstFull.preview)
        #expect(fullTail !== atLimit.preview)
        #expect(isClose(Array(rows(of: fullTail)[3..<11]), updated.rows(68..<76)))

        #expect(step(updated.frame(at: 50, height: frameHeight)) == nil)
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

    /// Whether two lists of rows are the same, give or take the noise that
    /// every frame gets on its way to the stitcher (see the end of the file).
    private func isClose(_ a: [[UInt8]], _ b: [[UInt8]]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { rowA, rowB in
            rowA.count == rowB.count && zip(rowA, rowB).allSatisfy { abs(Int($0) - Int($1)) <= 1 }
        }
    }

    /// The picture's rows, each as its bytes.
    private func rows(of stitcher: ScrollStitcher) -> [[UInt8]] {
        guard let image = stitcher.makeImage(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return [] }
        return rows(of: image)
    }

    private func rows(of image: CGImage) -> [[UInt8]] {
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

    mutating func paint(columns: Range<Int>, rows rowRange: Range<Int>, value: UInt8) {
        var slice = Slice(rows: rows)
        slice.paint(columns: columns, rows: rowRange, value: value)
        rows = slice.rows
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

        /// Adds 0 or 1 at random to the colour bytes, but not to alpha.
        func withNoise() -> Slice {
            Self.noiseCount += 1
            var generator = Generator(seed: 1000 + Self.noiseCount)
            var noisy = self
            for y in noisy.rows.indices {
                for index in noisy.rows[y].indices where index % 4 != 3 && noisy.rows[y][index] < 255 {
                    noisy.rows[y][index] += UInt8(generator.next() & 1)
                }
            }
            return noisy
        }

        private static var noiseCount: UInt64 = 0

        /// Halves every byte, the way a see-through bar dims what is under it.
        mutating func dim(rows rowRange: Range<Int>) {
            for y in rowRange {
                rows[y] = rows[y].map { $0 / 2 }
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

    fileprivate struct Generator {
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
    /// Every frame gets faint noise first, as on a real screen: macOS adds
    /// some to the colours each time it draws (dithering), so the same
    /// content never comes out exactly the same twice.
    mutating func add(_ slice: Document.Slice) -> Outcome {
        slice.withNoise().withFrame { add($0) }
    }
}
