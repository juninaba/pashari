import AppKit
import Testing

@testable import Pashari

@MainActor
struct ThumbnailLayoutTests {
    @Test func largeScreenshotIsScaledDownKeepingItsProportions() {
        let size = ThumbnailLayout.previewSize(for: CGSize(width: 1728, height: 1080))

        #expect(size == CGSize(width: 240, height: 150))
    }

    @Test func tallScreenshotIsLimitedByHeight() {
        let size = ThumbnailLayout.previewSize(for: CGSize(width: 400, height: 800))

        #expect(size.height == 160)
        // 80 wide by proportion, widened to the minimum so the buttons fit.
        #expect(size.width == ThumbnailLayout.minimumPreviewSize.width)
    }

    @Test func aVeryTallScreenshotShowsItsTopInTheWidestPreview() {
        let size = CGSize(width: 480, height: 5000)

        // Whole, it would be a strip 15 points wide. Its top instead, in the
        // shape of the largest preview, 240 × 160, at half its size.
        #expect(ThumbnailLayout.previewedPart(of: size) == CGRect(x: 0, y: 0, width: 480, height: 320))
        #expect(ThumbnailLayout.previewSize(for: size) == CGSize(width: 240, height: 160))
        #expect(ThumbnailLayout.cardSize(for: size).width == 240 + 2 * ThumbnailLayout.paperBorder)
    }

    @Test func aNarrowVeryTallScreenshotShowsItsTopAtItsRealSize() {
        let size = CGSize(width: 50, height: 5000)

        #expect(ThumbnailLayout.previewedPart(of: size) == CGRect(x: 0, y: 0, width: 50, height: 160))
        // Widened to the minimum, so the buttons fit.
        #expect(ThumbnailLayout.previewSize(for: size) == CGSize(width: 148, height: 160))
    }

    @Test func aTallWindowStillShowsWhole() {
        #expect(ThumbnailLayout.previewedPart(of: CGSize(width: 400, height: 800)) == nil)
        #expect(ThumbnailLayout.previewedPart(of: CGSize(width: 1728, height: 1080)) == nil)
    }

    @Test func smallScreenshotIsNotScaledUp() {
        let size = ThumbnailLayout.previewSize(for: CGSize(width: 200, height: 100))

        #expect(size == CGSize(width: 200, height: 100))
    }

    @Test func tinyScreenshotGetsTheMinimumSize() {
        let size = ThumbnailLayout.previewSize(for: CGSize(width: 10, height: 10))

        #expect(size == ThumbnailLayout.minimumPreviewSize)
    }

    @Test func cardPutsPaperAroundThePreviewAndTheToolbarUnderIt() {
        let card = ThumbnailLayout.cardSize(for: CGSize(width: 1728, height: 1080))

        // 8 points of paper at the sides and the top, and the buttons below.
        #expect(card == CGSize(width: 256, height: 150 + 8 + ThumbnailLayout.toolbarHeight))
        #expect(
            ThumbnailLayout.previewFrame(inCardOf: card)
                == CGRect(x: 8, y: ThumbnailLayout.toolbarHeight, width: 240, height: 150)
        )
    }

    @Test func cardsStackUpwardsFromTheBottomLeftCorner() {
        let area = CGRect(x: 100, y: 50, width: 1000, height: 700)
        let sizes = [CGSize(width: 240, height: 184), CGSize(width: 200, height: 134)]

        let frames = ThumbnailLayout.stackFrames(for: sizes, in: area)

        #expect(frames == [
            CGRect(x: 116, y: 66, width: 240, height: 184),
            CGRect(x: 116, y: 66 + 184 + 12, width: 200, height: 134),
        ])
    }

    @Test func onlyTheCardsThatFitTheScreenHeightStay() {
        let sizes = Array(repeating: CGSize(width: 240, height: 184), count: 5)

        // 16 + 3 × 184 + 2 × 12 = 592 fits below 700 - 16; a fourth card
        // would reach 788.
        let small = CGRect(x: 0, y: 0, width: 1000, height: 700)
        #expect(ThumbnailLayout.fittingCount(for: sizes, in: small) == 3)
        let large = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        #expect(ThumbnailLayout.fittingCount(for: sizes, in: large) == 5)
    }

    @Test func theNewestCardStaysEvenWhenNothingFits() {
        let sizes = [CGSize(width: 240, height: 184)]
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 100)

        #expect(ThumbnailLayout.fittingCount(for: sizes, in: tiny) == 1)
    }

    @Test func theNewestCardLiesUprightInTheCornerOfThePile() {
        let area = CGRect(x: 100, y: 50, width: 1000, height: 700)
        let sizes = [CGSize(width: 256, height: 194), CGSize(width: 256, height: 120)]

        let pile = ThumbnailLayout.pilePlacements(for: sizes, in: area)

        // Where the column of spread-out cards starts too, so the newest
        // card stays put when the pile spreads out.
        #expect(pile.first == ThumbnailLayout.Placement(
            frame: ThumbnailLayout.stackFrames(for: sizes, in: area)[0],
            angle: 0
        ))
    }

    @Test func olderCardsShowTheirTopsAboveTheNewestOne() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let newest = CGSize(width: 256, height: 194)
        let shorter = CGSize(width: 200, height: 100)
        let taller = CGSize(width: 256, height: 250)

        let pile = ThumbnailLayout.pilePlacements(for: [newest, shorter, taller, newest, newest], in: area)

        let newestTop = 16 + newest.height
        #expect(pile[1].frame.maxY == newestTop + 10)
        // A tall card stands on the newest card's baseline instead of
        // reaching below it, and shows even more of itself.
        #expect(pile[2].frame.minY == 16)
        #expect(pile[2].frame.maxY > newestTop + 18)
        #expect(pile.allSatisfy { $0.frame.minY >= 16 })
        // Each further back shows a little more, turned the other way.
        #expect(pile[3].frame.maxY > pile[1].frame.maxY)
        #expect(pile[4].frame.maxY > pile[3].frame.maxY)
        for (front, back) in zip(pile.dropFirst(), pile.dropFirst(2)) {
            #expect(front.angle * back.angle < 0)
        }
        #expect(pile.dropFirst().allSatisfy { abs($0.angle) <= 6 * .pi / 180 })
    }

    @Test func aspectFitCentresThePicture() {
        let fitted = ThumbnailPreviewView.aspectFit(
            CGSize(width: 400, height: 100),
            in: CGRect(x: 0, y: 0, width: 200, height: 200)
        )

        #expect(fitted == CGRect(x: 0, y: 75, width: 200, height: 50))
    }
}

@MainActor
struct ThumbnailControllerTests {
    @Test func closingImmediatelyAfterSaveWaitsForTheCaptureToBeDelivered() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "saved")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var errors = 0
        let controller = ThumbnailController(
            storage: CaptureStorage(rootDirectory: root.appending(path: "working")),
            saveDirectory: { destination },
            showError: { _, _ in errors += 1 }
        )
        let screenshot = makeScreenshot()
        controller.show(screenshot)
        let card = try #require(controller.cards.first)
        defer { card.onClose?() }
        let buttons = card.subviews.flatMap(\.subviews).compactMap { $0 as? NSButton }
        try #require(buttons.count == 4)

        // Both actions run before the preparation or delivery task can finish.
        card.onSave?()
        card.onClose?()
        #expect(controller.pendingCount == 1)
        #expect(buttons.allSatisfy { !$0.isEnabled })
        #expect(card.previewView.fileURL?() == nil)

        for _ in 0..<200 where controller.hasPendingCaptures && errors == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(errors == 0)
        #expect(!controller.hasPendingCaptures)
        let saved = destination.appending(path: ScreenshotWriter.fileName(capturedAt: screenshot.capturedAt))
        let expected = try await ScreenshotWriter.pngData(for: screenshot)
        #expect(try Data(contentsOf: saved) == expected)
    }

    @Test func aFailedSaveReenablesActionsAndKeepsTheCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "not-a-directory")
        try Data().write(to: destination)
        var errors = 0
        let controller = ThumbnailController(
            storage: CaptureStorage(rootDirectory: root.appending(path: "working")),
            saveDirectory: { destination },
            showError: { _, _ in errors += 1 }
        )
        controller.show(makeScreenshot())
        let card = try #require(controller.cards.first)
        defer { card.onClose?() }
        card.onSave?()
        card.onClose?()

        for _ in 0..<200 where errors == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(errors == 1)
        #expect(controller.pendingCount == 1)
        let buttons = card.subviews.flatMap(\.subviews).compactMap { $0 as? NSButton }
        #expect(buttons.allSatisfy { $0.isEnabled })
        let file = try #require(card.previewView.fileURL?())
        #expect(FileManager.default.fileExists(atPath: file.path))
        card.onClose?()
        #expect(!controller.hasPendingCaptures)
    }

    @Test func overflowCapturesKeepTheirFilesAndReturnWhenThereIsRoom() async throws {
        let controller = ThumbnailController()
        defer {
            while let card = controller.cards.first { close(card) }
        }
        #expect(!controller.hasPendingCaptures)

        controller.show(makeScreenshot())
        weak var oldCard: ThumbnailCardView?
        let file: URL
        do {
            let card = try #require(controller.cards.first)
            oldCard = card
            for _ in 0..<100 where card.previewView.fileURL?() == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            file = try #require(card.previewView.fileURL?())
        }

        for _ in 0...ThumbnailLayout.maximumCount {
            controller.show(makeScreenshot())
        }
        #expect(controller.pendingCount == ThumbnailLayout.maximumCount + 2)
        #expect(controller.cards.count <= ThumbnailLayout.maximumCount)
        #expect(controller.hasPendingCaptures)

        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: NSApp
        )
        // AppKit may hold on to the view briefly, but it must leave the
        // window when its capture leaves the visible stack.
        if let oldCard {
            #expect(oldCard.superview == nil)
        }
        #expect(controller.pendingCount == ThumbnailLayout.maximumCount + 2)
        #expect(FileManager.default.fileExists(atPath: file.path))

        while controller.pendingCount > 1 {
            close(try #require(controller.cards.first))
        }
        let restoredCard = try #require(controller.cards.first)
        #expect(restoredCard.window?.isVisible == true)
        #expect(controller.cards.count == 1)
        #expect(restoredCard.previewView.fileURL?() == file)
        for _ in 0..<100 where !restoredCard.hasPicture {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(restoredCard.hasPicture)
        #expect(FileManager.default.fileExists(atPath: file.path))

        var annotated: Screenshot?
        controller.onAnnotate = { annotated = $0 }
        restoredCard.onAnnotate?()
        for _ in 0..<100 where annotated == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let screenshot = try #require(annotated)
        #expect(screenshot.image.width == 200)
        #expect(screenshot.image.height == 120)
        #expect(screenshot.scale == 2)
        #expect(TestImages.pixel(of: screenshot.image, x: 20, y: 20) == .blue)
        #expect(!controller.hasPendingCaptures)
    }

    @Test func aThumbnailForADisplayThatIsGoneMovesToTheScreenInUse() throws {
        let controller = ThumbnailController()
        // No screen has this ID, as if its display had just been unplugged.
        controller.show(makeScreenshot(), onDisplay: 0xDEAD_BEEF)
        let card = try #require(controller.cards.first)
        defer { close(card) }

        let screen = try #require(NSScreen.underMouse ?? NSScreen.main)
        let expected = ThumbnailLayout.stackFrames(for: [card.frame.size], in: screen.visibleFrame)
        #expect(card.window?.convertToScreen(card.frame) == expected.first)
    }

    @Test func aDroppedThumbnailKeepsItsFullSizePNGUntilANormalQuit() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let legacy = root.appending(path: UUID().uuidString).appending(path: UUID().uuidString)
        try manager.createDirectory(at: legacy, withIntermediateDirectories: true)
        let screenshot = makeScreenshot()
        let file = legacy.appending(path: ScreenshotWriter.fileName(capturedAt: screenshot.capturedAt))
        let png = try await ScreenshotWriter.pngData(for: screenshot)
        try png.write(to: file)

        let dragURL: URL
        do {
            let storage = CaptureStorage(rootDirectory: root)
            let controller = ThumbnailController(storage: storage)
            try storage.withInterruptedFiles(includeLegacy: { true }) { try controller.restore($0) }
            let card = try #require(controller.cards.first)
            defer { card.onClose?() }
            dragURL = try #require(card.previewView.fileURL?())

            #expect(dragURL.lastPathComponent == file.lastPathComponent)
            card.previewView.onDrop?()
            #expect(!controller.hasPendingCaptures)
        }

        // The app was interrupted after handing off the URL.
        let next = CaptureStorage(rootDirectory: root)
        try next.withInterruptedFiles(includeLegacy: { true }) { #expect($0.isEmpty) }
        #expect(try Data(contentsOf: dragURL) == png)
        next.removeFiles()
        #expect(!manager.fileExists(atPath: dragURL.deletingLastPathComponent().deletingLastPathComponent().path))
    }

    @Test func thumbnailsAreLaidOutAgainWhenDisplaysChange() async throws {
        let controller = ThumbnailController()
        controller.show(makeScreenshot())
        let card = try #require(controller.cards.first)
        defer { close(card) }
        let panel = try #require(card.window)
        let home = panel.frame
        // Far from any screen, where a layout for a display that is gone
        // would leave it.
        panel.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))

        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: NSApp
        )
        for _ in 0..<100 where panel.frame != home {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(panel.frame == home)
    }

    @Test func olderCapturesPileUpBehindTheNewestWithItsCount() throws {
        let controller = ThumbnailController()
        defer {
            while let card = controller.cards.first { close(card) }
        }
        controller.show(makeScreenshot())
        controller.show(makeScreenshot())
        controller.show(makeScreenshot())
        let cards = controller.cards
        try #require(cards.count == 3)
        let stack = try #require(cards[0].superview as? ThumbnailStackView)
        let panel = try #require(stack.window)
        let screen = try #require(NSScreen.underMouse ?? NSScreen.main)

        let pile = ThumbnailLayout.pilePlacements(for: cards.map(\.frame.size), in: screen.visibleFrame)
        #expect(cards.map { panel.convertToScreen($0.frame) } == pile.map(\.frame))
        for (card, placement) in zip(cards, pile) {
            let angle = atan2(card.paper.transform.m12, card.paper.transform.m11)
            #expect(abs(angle - placement.angle) < 1e-9)
        }
        #expect(cards.map(\.badgeCount) == [3, nil, nil])
        // The newest lies on top.
        #expect(stack.subviews.last === cards[0])
        // All three fit in the window, both piled up and spread out.
        let column = ThumbnailLayout.stackFrames(for: cards.map(\.frame.size), in: screen.visibleFrame)
        #expect((pile.map(\.frame) + column).allSatisfy { panel.frame.contains($0) })
    }

    @Test func restingThePointerOnThePileSpreadsItOutAndLeavingPilesItUpAgain() async throws {
        let controller = ThumbnailController()
        defer {
            while let card = controller.cards.first { close(card) }
        }
        controller.show(makeScreenshot())
        controller.show(makeScreenshot())
        let cards = controller.cards
        let stack = try #require(cards[0].superview as? ThumbnailStackView)
        let panel = try #require(stack.window)
        let screen = try #require(NSScreen.underMouse ?? NSScreen.main)
        let column = ThumbnailLayout.stackFrames(for: cards.map(\.frame.size), in: screen.visibleFrame)
        // AppKit asks the view to look at the pointer again now and then.
        // The real one is elsewhere: tests leave it alone.
        var pointer = CGPoint(x: column[0].midX, y: column[0].midY)
        stack.pointerLocation = { pointer }

        stack.mouseEntered(with: try enterExitEvent(.mouseEntered))
        #expect(!stack.isSpread)
        for _ in 0..<50 where !stack.isSpread {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(stack.isSpread)
        #expect(cards.map { panel.convertToScreen($0.frame) } == column)
        #expect(cards.allSatisfy { CATransform3DIsIdentity($0.paper.transform) })
        #expect(cards[0].badgeCount == nil)

        pointer = CGPoint(x: screen.frame.maxX - 1, y: screen.frame.maxY - 1)
        stack.mouseExited(with: try enterExitEvent(.mouseExited))
        for _ in 0..<100 where stack.isSpread {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!stack.isSpread)
        #expect(cards[0].badgeCount == 2)
    }

    @Test func eachCardShowsItsButtonIcons() throws {
        let card = ThumbnailCardView(imageSize: CGSize(width: 400, height: 300))
        let buttons = card.subviews.flatMap(\.subviews).compactMap { $0 as? ThumbnailButton }

        #expect(buttons.count == 4)
        for button in buttons {
            #expect(button.look.superlayer === card.paper)
            #expect(button.look.sublayers?.contains { $0.contents != nil } == true)
        }
    }

    private func enterExitEvent(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))
    }

    private func close(_ card: ThumbnailCardView) {
        card.onClose?()
    }
}

@MainActor
struct PendingCaptureTests {
    @Test func restoresTheFullImageAndMetadataFromItsPNG() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = CaptureStorage(rootDirectory: directory)
        let original = Screenshot(
            image: TestImages.make(width: 60, height: 40, patchRect: CGRect(x: 0, y: 0, width: 10, height: 10)),
            scale: 2, capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let capture = PendingCapture(screenshot: original, storage: storage)
        _ = try await capture.fileURL()

        let restored = try await capture.screenshot()
        #expect(restored.image !== original.image)
        #expect(restored.pointSize == original.pointSize)
        #expect(restored.scale == original.scale)
        #expect(restored.capturedAt == original.capturedAt)
        #expect(TestImages.pixel(of: restored.image, x: 5, y: 5) == .red)
        #expect(TestImages.pixel(of: restored.image, x: 20, y: 20) == .blue)
        let thumbnail = try await capture.thumbnail(maxPixelSize: 20)
        #expect(thumbnail.width == 20)
        #expect(thumbnail.height <= 20)
    }

    @Test func releasesTheOriginalPixelsAfterWritingEvenWhileAPreviewIsHeld() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = CaptureStorage(rootDirectory: directory)
        let released = DispatchSemaphore(value: 0)
        let capture = PendingCapture(
            screenshot: Screenshot(image: TestImages.tracked(released: released), scale: 2, capturedAt: Date()),
            storage: storage
        )
        let thumbnail = try await capture.thumbnail(maxPixelSize: 20)
        _ = try await capture.fileURL()

        func sourceWasReleased() -> Bool {
            released.wait(timeout: .now()) == .success
        }
        var pixelsReleased = false
        for _ in 0..<100 {
            if sourceWasReleased() {
                pixelsReleased = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(pixelsReleased)
        #expect(thumbnail.width == 20)
        #expect(try await capture.screenshot().image.width == 60)
    }

    @Test func aThumbnailOfAPartShowsOnlyThatPart() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = CaptureStorage(rootDirectory: directory)
        // Red at the top, blue below.
        let original = Screenshot(
            image: TestImages.make(width: 20, height: 200, patchRect: CGRect(x: 0, y: 0, width: 20, height: 20)),
            scale: 2,
            capturedAt: Date()
        )
        let capture = PendingCapture(screenshot: original, storage: storage)
        let top = CGRect(x: 0, y: 0, width: 10, height: 10)

        let fromMemory = try await capture.thumbnail(of: top, maxPixelSize: 20)
        _ = try await capture.fileURL()
        let fromFile = try await capture.thumbnail(of: top, maxPixelSize: 20)

        for thumbnail in [fromMemory, fromFile] {
            #expect(thumbnail.width == 20)
            #expect(thumbnail.height == 20)
            #expect(TestImages.pixel(of: thumbnail, x: 10, y: 18) == .red)
        }
    }

    @Test func aSmallerThumbnailOfAPartReadFromTheFileShowsOnlyThatPart() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = CaptureStorage(rootDirectory: directory)
        // Red at the top, blue below.
        let original = Screenshot(
            image: TestImages.make(width: 20, height: 200, patchRect: CGRect(x: 0, y: 0, width: 20, height: 20)),
            scale: 2,
            capturedAt: Date()
        )
        let capture = PendingCapture(screenshot: original, storage: storage)
        _ = try await capture.fileURL()

        // Half as many pixels as the part has: the file is read at half its
        // size, where a point is one pixel.
        let thumbnail = try await capture.thumbnail(of: CGRect(x: 0, y: 0, width: 10, height: 10), maxPixelSize: 10)

        #expect(thumbnail.width == 10)
        #expect(thumbnail.height == 10)
        #expect(TestImages.pixel(of: thumbnail, x: 5, y: 5) == .red)
    }

    @Test func keepsTheOriginalWhenWritingTheTemporaryFileFails() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data().write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let original = makeScreenshot()
        let capture = PendingCapture(screenshot: original, storage: CaptureStorage(rootDirectory: path))
        await #expect(throws: (any Error).self) { try await capture.fileURL() }

        #expect(capture.readyFileURL == nil)
        let restored = try await capture.screenshot()
        #expect(restored.image === original.image)
        #expect(try await capture.thumbnail(maxPixelSize: 20).width == 20)
    }

    @Test func preparesAPNGFileNamedAfterTheCaptureTime() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pashari-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = CaptureStorage(rootDirectory: directory)
        let screenshot = Screenshot(
            image: TestImages.make(width: 60, height: 40),
            scale: 2,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let capture = PendingCapture(screenshot: screenshot, storage: storage)
        let file = try await capture.file()

        #expect(file.url.path.hasPrefix(directory.path))
        #expect(file.url.lastPathComponent == ScreenshotWriter.fileName(capturedAt: screenshot.capturedAt))
        #expect(try Data(contentsOf: file.url) == file.data)
        // Every PNG file starts with these eight bytes.
        #expect(file.data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    @Test func twoCapturesFromTheSameSecondDoNotCollide() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pashari-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = CaptureStorage(rootDirectory: directory)
        let screenshot = Screenshot(
            image: TestImages.make(width: 10, height: 10),
            scale: 1,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let first = try await PendingCapture(screenshot: screenshot, storage: storage).file()
        let second = try await PendingCapture(screenshot: screenshot, storage: storage).file()

        #expect(first.url != second.url)
        #expect(first.url.lastPathComponent == second.url.lastPathComponent)
    }

    @Test func removingTheFileDeletesItsFolder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pashari-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = CaptureStorage(rootDirectory: directory)
        let screenshot = Screenshot(
            image: TestImages.make(width: 10, height: 10),
            scale: 1,
            capturedAt: Date()
        )
        let capture = PendingCapture(screenshot: screenshot, storage: storage)
        let file = try await capture.file()

        await capture.removeFile()

        #expect(!FileManager.default.fileExists(atPath: file.url.deletingLastPathComponent().path))
    }

    @Test func aFileRemovedBeforeItIsWrittenDoesNotAppearLater() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pashari-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = CaptureStorage(rootDirectory: directory)
        let screenshot = Screenshot(
            image: TestImages.make(width: 10, height: 10),
            scale: 1,
            capturedAt: Date()
        )

        // Closed straight away, while the PNG may still be encoding.
        await PendingCapture(screenshot: screenshot, storage: storage).removeFile()

        #expect(try FileManager.default.contentsOfDirectory(atPath: storage.directory.path).isEmpty)
    }
}

@MainActor
struct ClipboardTests {
    @Test func copyReplacesThePasteboardContentsWithThePNG() {
        // A private pasteboard, so the test leaves the real clipboard alone.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pashari-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("old text", forType: .string)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

        Clipboard.copy(pngData: png, to: pasteboard)

        #expect(pasteboard.data(forType: .png) == png)
        #expect(pasteboard.string(forType: .string) == nil)
    }
}
