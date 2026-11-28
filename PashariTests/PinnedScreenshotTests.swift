import AppKit
import ImageIO
import Testing

@testable import Pashari

@MainActor
@Suite(.takesTurnsOnTheScreen)
struct PinnedScreenshotTests {
    @Test func unpinReturnsTheSameUnsavedCaptureToTheThumbnails() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let capture = fixture.makeCapture()
        let file = try await capture.fileURL()
        let panel = try fixture.show(capture)
        #expect(fixture.pins.hasPendingCaptures)
        #expect(panel.level == ThumbnailPanel.windowLevel)
        #expect(panel.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary]))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)

        panel.onUnpin?()

        #expect(!panel.isVisible)
        #expect(fixture.pins.panels.isEmpty)
        let card = try #require(fixture.thumbnails.cards.first)
        #expect(card.previewView.fileURL?() == file)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test(arguments: [false, true])
    func copyAndSaveDeliverTheFullPNGAndKeepThePinVisible(save: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let capture = fixture.makeCapture()
        let file = try await capture.file()
        let panel = try fixture.show(capture)

        if save { panel.onSave?() } else { panel.onCopy?() }
        try await waitFor { !fixture.pins.hasPendingCaptures }

        if save {
            #expect(try Data(contentsOf: fixture.output.appending(path: file.url.lastPathComponent)) == file.data)
        } else {
            #expect(fixture.pasteboard.data(forType: .png) == file.data)
        }
        #expect(panel.isVisible)
        #expect(fixture.pins.panels.count == 1)
        panel.onUnpin?()
        #expect(!fixture.thumbnails.hasPendingCaptures)
        try await waitFor { !FileManager.default.fileExists(atPath: file.url.path) }
    }

    @Test func aCompletedDropLeavesThePinAndTheReceiversFileInPlace() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let capture = fixture.makeCapture()
        let file = try await capture.fileURL()
        let panel = try fixture.show(capture)
        #expect(panel.fileURL?() == file)

        panel.onDrop?()

        #expect(!fixture.pins.hasPendingCaptures)
        #expect(panel.isVisible)
        panel.onUnpin?()
        #expect(!fixture.thumbnails.hasPendingCaptures)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func annotateTakesTheFullScreenshotAndReturnsTheEditToTheThumbnails() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let capture = fixture.makeCapture()
        let file = try await capture.fileURL()
        let panel = try fixture.show(capture)
        var input: Screenshot?
        var finish: ((Screenshot?) -> Void)?
        fixture.pins.onAnnotate = {
            input = $0
            finish = $1
        }

        panel.onAnnotate?()
        try await waitFor { input != nil }

        let source = try #require(input)
        #expect(source.image.width == 320 && source.image.height == 200)
        #expect(source.screenFrame?.maxY == panel.imageFrame.maxY)
        #expect(!panel.isVisible)
        #expect(!fixture.thumbnails.hasPendingCaptures)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let edited = try #require(source.cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32)))
        finish?(edited)

        let card = try #require(fixture.thumbnails.cards.first)
        try await waitFor { !FileManager.default.fileExists(atPath: file.path) }
        let editedURL = try #require(card.previewView.fileURL?())
        let imageSource = try #require(CGImageSourceCreateWithURL(editedURL as CFURL, nil))
        let png = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        #expect(png.width == 128 && png.height == 64)
    }

    @Test func cancellingQuitBringsUnsavedPinsBackToTheFront() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let delegate = AppDelegate(thumbnailController: fixture.thumbnails, pinController: fixture.pins)
        var questions = 0
        delegate.confirmQuit = {
            questions += 1
            return false
        }
        let capture = fixture.makeCapture()
        _ = try await capture.fileURL()
        let panel = try fixture.show(capture)
        panel.orderOut(nil)

        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateCancel)
        #expect(questions == 1)
        #expect(panel.isVisible)
        panel.onUnpin?()
        fixture.thumbnails.cards.first?.onClose?()
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
    }

    @Test func aDisplayChangeBringsAnOffScreenPinBack() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let capture = fixture.makeCapture()
        _ = try await capture.fileURL()
        let panel = try fixture.show(capture)
        let screen = try #require(panel.screen)
        let outside = (NSScreen.screens.map { $0.frame.maxX }.max() ?? screen.frame.maxX) + 1000
        panel.setFrameOrigin(CGPoint(x: outside, y: screen.frame.minY))

        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)

        #expect(screen.visibleFrame.contains(panel.frame))
    }

    @Test func scrollingResizesAPinAndOptionScrollingAdjustsOpacityWithoutFocus() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let capture = fixture.makeCapture()
        _ = try await capture.fileURL()
        let frontmostApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let panel = try fixture.show(capture)
        let content = try #require(panel.contentView)
        let startSize = panel.imageFrame.size
        let scroll = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0
        ))
        content.scrollWheel(with: try #require(NSEvent(cgEvent: scroll)))
        let resized = panel.imageFrame.size
        #expect(resized.width < startSize.width)
        #expect(abs(resized.width / resized.height - startSize.width / startSize.height) < 0.001)

        scroll.flags = .maskAlternate
        content.scrollWheel(with: try #require(NSEvent(cgEvent: scroll)))
        #expect(panel.alphaValue < 1)
        #expect(panel.imageFrame.size == resized)
        #expect(!panel.isKeyWindow)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostApp)

        scroll.flags = []
        scroll.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 1)
        let momentum = try #require(NSEvent(cgEvent: scroll))
        try #require(!momentum.momentumPhase.isEmpty)
        content.scrollWheel(with: momentum)
        #expect(panel.imageFrame.size == resized)

        let pinnedFrame = panel.imageFrame
        panel.onUnpin?()
        #expect(capture.screenFrame == pinnedFrame)
    }

    @Test func aScrollCaptureHidesOverlappingPinsUntilItEnds() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let first = fixture.makeCapture()
        let second = fixture.makeCapture()
        _ = try await first.fileURL()
        _ = try await second.fileURL()
        let existing = try fixture.show(first)

        fixture.pins.showPins(avoiding: existing.frame)
        #expect(!existing.isVisible)
        let addedDuringCapture = try fixture.show(second)
        #expect(!addedDuringCapture.isVisible)
        #expect(fixture.pins.hasPendingCaptures)

        fixture.pins.showPins(avoiding: nil)
        #expect(existing.isVisible && addedDuringCapture.isVisible)
        #expect(existing.frame.origin != addedDuringCapture.frame.origin)
    }

    @Test func recordingKeepsPinsHiddenUntilItEnds() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let first = fixture.makeCapture()
        let second = fixture.makeCapture()
        _ = try await first.fileURL()
        _ = try await second.fileURL()
        let existing = try fixture.show(first)
        #expect(existing.isVisible)

        fixture.pins.isRecording = true
        let addedDuringRecording = try fixture.show(second)
        fixture.pins.showPendingPins()
        #expect(!existing.isVisible && !addedDuringRecording.isVisible)
        #expect(fixture.pins.hasPendingCaptures)

        fixture.pins.isRecording = false
        #expect(existing.isVisible && addedDuringRecording.isVisible)
    }

    @Test func pickingAWindowHidesPinsUntilItEnds() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let capture = fixture.makeCapture()
        _ = try await capture.fileURL()
        let panel = try fixture.show(capture)
        #expect(panel.isVisible)

        // With no windows to pick, the selection waits until it is cancelled.
        let selection = Task { await WindowSelectionSession().run(with: []) == nil }
        try await waitFor { WindowSelectionSession.isActive }
        #expect(!panel.isVisible)

        OverlayPanel.cancelSelection()
        #expect(await selection.value)
        #expect(!WindowSelectionSession.isActive)
        #expect(panel.isVisible)
    }

    @Test func anInterruptedPinCanBeRecoveredAsAThumbnail() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let root = fixture.root.appending(path: "recovery")
        let file: URL
        do {
            let storage = CaptureStorage(rootDirectory: root)
            let pins = PinnedScreenshotController(storage: storage)
            let capture = PendingCapture(screenshot: fixture.screenshot, storage: storage)
            file = try await capture.fileURL()
            #expect(pins.show(capture))
            pins.panels.first?.close()
        }

        let next = CaptureStorage(rootDirectory: root)
        try next.withInterruptedFiles(includeLegacy: { false }) { files in
            #expect(files.map { $0.resolvingSymlinksInPath() } == [file.resolvingSymlinksInPath()])
            try fixture.thumbnails.restore(files)
        }
        #expect(fixture.thumbnails.cards.first?.previewView.fileURL?()?.lastPathComponent == file.lastPathComponent)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let pasteboard = NSPasteboard.withUniqueName()
        let thumbnails: ThumbnailController
        let pins: PinnedScreenshotController
        var output: URL { root.appending(path: "output") }
        let screenshot = Screenshot(image: TestImages.make(width: 320, height: 200), scale: 2, capturedAt: Date())

        init() throws {
            let storage = CaptureStorage(rootDirectory: root.appending(path: "pending"))
            let output = root.appending(path: "output")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            thumbnails = ThumbnailController(storage: storage)
            pins = PinnedScreenshotController(
                storage: storage, saveDirectory: { output },
                showError: { error, _ in Issue.record(error) }, pasteboard: pasteboard
            )
            pins.onUnpin = { [thumbnails] in thumbnails.show($0, onDisplay: $1) }
        }

        func makeCapture() -> PendingCapture {
            PendingCapture(screenshot: screenshot, storage: thumbnails.storage)
        }

        func show(_ capture: PendingCapture) throws -> PinnedScreenshotPanel {
            try #require(pins.show(capture))
            return try #require(pins.panels.last)
        }

        func cleanUp() {
            for panel in pins.panels { panel.onUnpin?() }
            while let card = thumbnails.cards.first { card.onClose?() }
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
