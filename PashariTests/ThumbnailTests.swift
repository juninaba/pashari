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

    @Test func eachOlderCardShowsItsTopAboveAllCardsInFrontOfIt() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let newest = CGSize(width: 256, height: 194)
        let shorter = CGSize(width: 200, height: 100)
        let taller = CGSize(width: 256, height: 250)

        let pile = ThumbnailLayout.pilePlacements(for: [newest, shorter, taller, newest, newest], in: area)

        #expect(pile[1].frame.maxY == 16 + newest.height + 10)
        // A tall card stands on the newest card's baseline instead of
        // reaching below it.
        #expect(pile[2].frame.minY == 16)
        #expect(pile.allSatisfy { $0.frame.minY >= 16 })
        // Even behind the tall card, the next ones still show.
        for index in 1..<pile.count {
            let inFront = pile[..<index].map(\.frame.maxY).max() ?? 0
            #expect(pile[index].frame.maxY > inFront)
        }
        // Turned the other way from the card in front.
        for (front, back) in zip(pile.dropFirst(), pile.dropFirst(2)) {
            #expect(front.angle * back.angle < 0)
        }
        #expect(pile.dropFirst().allSatisfy { abs($0.angle) <= 6 * .pi / 180 })
    }

    @Test func aSmallCardBehindALargeOneStillShows() {
        let small = CGSize(width: 164, height: 92)
        let large = CGSize(width: 256, height: 204)

        let pile = ThumbnailLayout.pilePlacements(
            for: [small, large, small],
            in: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )

        #expect(pile[2].frame.maxY > pile[1].frame.maxY)
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
    @Test func pinningTransfersTheCaptureAndItsWorkingFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = CaptureStorage(rootDirectory: root)
        let controller = ThumbnailController(storage: storage)
        let screen = try #require(NSScreen.underMouse ?? NSScreen.main)
        let displayID = try #require(screen.displayID)
        let screenshot = makeScreenshot()
        let capture = PendingCapture(screenshot: screenshot, storage: storage)
        controller.show(capture, onDisplay: displayID)
        let card = try #require(controller.cards.first)
        let pinLabel = String(localized: "Pin to Screen")
        let pinButton = try #require(card.subviews.flatMap(\.subviews)
            .compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == pinLabel })
        var pinned: PendingCapture?
        controller.onPin = { result, display in
            #expect(display == displayID)
            #expect(!controller.hasPendingCaptures)
            pinned = result
        }
        defer { controller.onPin = nil }

        // A click can arrive before the PNG is ready.
        pinButton.performClick(nil)

        let result = try #require(pinned)
        #expect(result === capture)
        let file = try await result.file()
        #expect(file.data == (try await ScreenshotWriter.pngData(for: screenshot)))
        #expect(FileManager.default.fileExists(atPath: file.url.path))
    }

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
        try #require(buttons.count == 5)
        controller.onPin = { _, _ in Issue.record("Pin was called during Save") }

        // These actions run before the preparation or delivery task can finish.
        card.onSave?()
        card.onClose?()
        card.onPin?()
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

    @Test func aClickGoesToTheCardShownUnderThePointerWhileCardsMove() throws {
        let controller = ThumbnailController()
        defer {
            while let card = controller.cards.first { close(card) }
        }
        for _ in 0..<3 {
            controller.show(makeScreenshot())
        }
        let cards = controller.cards
        let stack = try #require(cards[0].superview as? ThumbnailStackView)
        let panel = try #require(stack.window)
        let newest = panel.convertToScreen(cards[0].frame)
        stack.pointerLocation = { CGPoint(x: newest.midX, y: newest.midY) }
        stack.setSpread(true)
        // Settle at once.
        cards.forEach { $0.paper.removeAllAnimations() }
        CATransaction.flush()
        let middle = cards[1]
        let middleClose = try #require(
            middle.subviews.flatMap(\.subviews).compactMap { $0 as? ThumbnailButton }.last
        )
        let closeFrame = middleClose.convert(middleClose.bounds, to: nil)
        let click = CGPoint(x: closeFrame.midX, y: closeFrame.midY)
        let target = try #require(stack.superview).convert(click, from: nil)
        #expect(stack.hitTest(target) === middleClose)
        let settled = cards.map(\.frame)

        // Closing the newest card moves the other two down: their views jump
        // there at once, their photos glide there. Hold the photos where
        // they started, whatever the motion settings: the oldest card's
        // Close is now where the middle card's still shows.
        close(cards[0])
        for (card, old) in zip(cards, settled).dropFirst() {
            card.paper.removeAllAnimations()
            CALayer.withoutAnimation {
                card.paper.transform = CATransform3DMakeTranslation(
                    old.minX - card.frame.minX,
                    old.minY - card.frame.minY,
                    0
                )
            }
        }
        CATransaction.flush()
        #expect(stack.hitTest(target) === middleClose)

        // A whole click there closes the middle card, the one shown there.
        // The button follows the mouse until it goes up. (A posted event gets
        // a wrong position in its window; without one it keeps its place on
        // the screen.)
        NSApp.postEvent(try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: panel.convertPoint(toScreen: click),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )), atStart: false)
        panel.sendEvent(try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: click,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )))
        #expect(!controller.cards.contains { $0 === middle })
        #expect(controller.cards.contains { $0 === cards[2] })
    }

    @Test func aClickOnAnOlderCardInThePileSpreadsItInsteadOfActing() throws {
        let controller = ThumbnailController()
        defer {
            while let card = controller.cards.first { close(card) }
        }
        // A wider card first, then a narrower one in front of it: a sliver of
        // the older card's Close sticks out, its icon hidden.
        controller.show(Screenshot(image: TestImages.make(width: 480, height: 300), scale: 2, capturedAt: Date()))
        controller.show(Screenshot(image: TestImages.make(width: 448, height: 280), scale: 2, capturedAt: Date()))
        let cards = controller.cards
        let front = cards[0]
        let behind = cards[1]
        let stack = try #require(front.superview as? ThumbnailStackView)
        let panel = try #require(stack.window)
        stack.pointerLocation = { CGPoint(x: -10_000, y: -10_000) }
        cards.forEach { $0.paper.removeAllAnimations() }
        CALayer.withoutAnimation { behind.paper.transform = CATransform3DIdentity }
        CATransaction.flush()
        let behindClose = try #require(
            behind.subviews.flatMap(\.subviews).compactMap { $0 as? ThumbnailButton }.last
        )
        let sliver = CGPoint(x: front.frame.maxX + 4, y: front.frame.minY + 20)
        try #require(behindClose.convert(behindClose.bounds, to: stack).contains(sliver))
        let click = stack.convert(sliver, to: nil)

        NSApp.postEvent(try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: panel.convertPoint(toScreen: click),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )), atStart: false)
        panel.sendEvent(try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: click,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )))

        #expect(controller.cards.contains { $0 === behind })
        #expect(stack.isSpread)
        // Nothing followed the mouse, so its mouse-up is still waiting.
        _ = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true)
    }

    @Test func releasingAButtonWhereAnotherCardCoversItDoesNothing() throws {
        let controller = ThumbnailController()
        defer {
            while let card = controller.cards.first { close(card) }
        }
        controller.show(makeScreenshot())
        controller.show(makeScreenshot())
        let cards = controller.cards
        let newer = cards[0]
        let older = cards[1]
        let stack = try #require(newer.superview as? ThumbnailStackView)
        let panel = try #require(stack.window)
        let newest = panel.convertToScreen(newer.frame)
        stack.pointerLocation = { CGPoint(x: newest.midX, y: newest.midY) }
        stack.setSpread(true)
        cards.forEach { $0.paper.removeAllAnimations() }
        // The older card still gliding down, its buttons half under the
        // newer card, which lies on top.
        CALayer.withoutAnimation { older.paper.transform = CATransform3DMakeTranslation(0, -30, 0) }
        CATransaction.flush()
        let olderClose = try #require(
            older.subviews.flatMap(\.subviews).compactMap { $0 as? ThumbnailButton }.last
        )
        let closeX = olderClose.convert(olderClose.bounds, to: stack).midX
        let pressed = stack.convert(CGPoint(x: closeX, y: newer.frame.maxY + 9), to: nil)
        let released = stack.convert(CGPoint(x: closeX, y: newer.frame.maxY - 9), to: nil)
        #expect(stack.hitTest(try #require(stack.superview).convert(pressed, from: nil)) === olderClose)

        // Pressed where it shows, let go over the newer card.
        NSApp.postEvent(try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: panel.convertPoint(toScreen: released),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )), atStart: false)
        panel.sendEvent(try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: pressed,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )))

        #expect(controller.cards.contains { $0 === older })
        #expect(controller.cards.contains { $0 === newer })
    }

    @Test func theWindowMakesRoomForCardsStillGlidingToTheirPlaces() throws {
        let controller = ThumbnailController()
        defer {
            while let card = controller.cards.first { close(card) }
        }
        controller.show(makeScreenshot())
        controller.show(makeScreenshot())
        let cards = controller.cards
        let stack = try #require(cards[0].superview as? ThumbnailStackView)
        let panel = try #require(stack.window)
        let newest = panel.convertToScreen(cards[0].frame)
        stack.pointerLocation = { CGPoint(x: newest.midX, y: newest.midY) }
        stack.setSpread(true)
        cards.forEach { $0.paper.removeAllAnimations() }
        // The top card shows well above its place, as if still on its way
        // down after a card below it closed.
        CALayer.withoutAnimation { cards[1].paper.transform = CATransform3DMakeTranslation(0, 60, 0) }
        CATransaction.flush()

        // Lays the cards out again, the window with them.
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)

        #expect(panel.frame.contains(panel.convertToScreen(cards[1].shownFrame)))
    }

    @Test func theSecondClickOfADoubleClickDoesNotReachTheNextCard() throws {
        let controller = ThumbnailController()
        defer {
            while let card = controller.cards.first { close(card) }
        }
        controller.show(makeScreenshot())
        controller.show(makeScreenshot())
        let cards = controller.cards
        let stack = try #require(cards[0].superview as? ThumbnailStackView)
        let panel = try #require(stack.window)
        stack.pointerLocation = { CGPoint(x: -10_000, y: -10_000) }
        cards.forEach { $0.paper.removeAllAnimations() }
        CATransaction.flush()
        let frontClose = try #require(
            cards[0].subviews.flatMap(\.subviews).compactMap { $0 as? ThumbnailButton }.last
        )
        let closeFrame = frontClose.convert(frontClose.bounds, to: nil)
        let point = CGPoint(x: closeFrame.midX, y: closeFrame.midY)
        func mouse(_ type: NSEvent.EventType, clickCount: Int) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type,
                location: type == .leftMouseUp ? panel.convertPoint(toScreen: point) : point,
                modifierFlags: [],
                timestamp: 0,
                // A posted event gets a wrong position in its window; without
                // one it keeps its place on the screen.
                windowNumber: type == .leftMouseUp ? 0 : panel.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: clickCount,
                pressure: type == .leftMouseUp ? 0 : 1
            ))
        }

        NSApp.postEvent(try mouse(.leftMouseUp, clickCount: 1), atStart: false)
        panel.sendEvent(try mouse(.leftMouseDown, clickCount: 1))
        #expect(!controller.cards.contains { $0 === cards[0] })
        // The next card comes to the front, its Close where the first one's
        // was. The second click of a double-click goes to the button there
        // once the first card has gone.
        cards[1].paper.removeAllAnimations()
        CALayer.withoutAnimation { cards[1].paper.transform = CATransform3DIdentity }
        CATransaction.flush()
        let target = try #require(stack.superview).convert(point, from: nil)
        let nextClose = try #require(stack.hitTest(target) as? ThumbnailButton)
        #expect(nextClose !== frontClose)
        NSApp.postEvent(try mouse(.leftMouseUp, clickCount: 2), atStart: false)
        nextClose.mouseDown(with: try mouse(.leftMouseDown, clickCount: 2))

        #expect(controller.cards.contains { $0 === cards[1] })
        // The ignored click's mouse-up is still waiting.
        _ = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true)
    }

    @Test func aDragThatEndsWithoutADropPilesTheCardsUpOnceThePointerIsAway() async throws {
        let controller = ThumbnailController()
        defer {
            while let card = controller.cards.first { close(card) }
        }
        controller.show(makeScreenshot())
        controller.show(makeScreenshot())
        let cards = controller.cards
        let stack = try #require(cards[0].superview as? ThumbnailStackView)
        let panel = try #require(stack.window)
        let newest = panel.convertToScreen(cards[0].frame)
        stack.pointerLocation = { CGPoint(x: newest.midX, y: newest.midY) }
        stack.setSpread(true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(stack.isSpread)

        // The pointer left during a drag, which sends no exit, and the drag
        // ended without a drop.
        stack.pointerLocation = { CGPoint(x: -10_000, y: -10_000) }
        cards[0].previewView.dragDidEnd(operation: [])
        for _ in 0..<100 where stack.isSpread {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!stack.isSpread)
        #expect(controller.cards.count == 2)
    }

    @Test func theSmallestScreenshotCardHasFiveLabeledButtonsWithRoomToClick() {
        let card = ThumbnailCardView(imageSize: CGSize(width: 10, height: 10))
        let buttons = card.subviews.flatMap(\.subviews).compactMap { $0 as? ThumbnailButton }

        let labels = [
            String(localized: "Copy"), String(localized: "Save"), String(localized: "Annotate"),
            String(localized: "Pin to Screen"), String(localized: "Close"),
        ]
        #expect(buttons.map { $0.accessibilityLabel() } == labels)
        #expect(buttons.map(\.toolTip) == labels)
        #expect(buttons.first?.frame.minX == 0)
        #expect(buttons.last?.frame.maxX == card.bounds.width)
        for button in buttons {
            #expect(button.frame.width >= 28)
            #expect(button.frame.height >= 28)
            #expect(button.look.superlayer === card.paper)
            #expect(button.look.sublayers?.contains { $0.contents != nil } == true)
        }
    }

    @Test func cardsTurnDarkInDarkModeAndLightAgain() throws {
        let panel = ThumbnailPanel()
        panel.appearance = NSAppearance(named: .aqua)
        let card = ThumbnailCardView(imageSize: CGSize(width: 400, height: 300))
        panel.stackView.addSubview(card)
        let icons = {
            card.subviews.flatMap(\.subviews).compactMap { $0 as? ThumbnailButton }
                .compactMap { $0.look.sublayers?.lazy.compactMap(\.contents).first }
                .map { ObjectIdentifier($0 as AnyObject) }
        }
        let lightIcons = icons()
        try #require(lightIcons.count == 5)
        #expect(card.paper.backgroundColor == ThumbnailStyle.Colors.light.paper)

        panel.appearance = NSAppearance(named: .darkAqua)
        #expect(card.paper.backgroundColor == ThumbnailStyle.Colors.dark.paper)
        #expect(card.paper.borderColor == ThumbnailStyle.Colors.dark.edge)
        let darkIcons = icons()
        #expect(darkIcons.count == 5)
        #expect(Set(darkIcons).isDisjoint(with: lightIcons))

        panel.appearance = NSAppearance(named: .aqua)
        #expect(card.paper.backgroundColor == ThumbnailStyle.Colors.light.paper)
        #expect(icons() == lightIcons)
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
    @Test func copyReplacesThePasteboardContentsWithThePNG() throws {
        // A private pasteboard, so the test leaves the real clipboard alone.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pashari-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("old text", forType: .string)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

        try Clipboard.copy(pngData: png, to: pasteboard)

        #expect(pasteboard.data(forType: .png) == png)
        #expect(pasteboard.string(forType: .string) == nil)
    }
}
