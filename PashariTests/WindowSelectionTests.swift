import AppKit
import Testing

@testable import Pashari

@MainActor
struct ScreenGeometryTests {
    @Test func flipsBetweenTopLeftAndBottomLeftOrigins() {
        let topLeftOrigin = CGRect(x: 50, y: 100, width: 300, height: 200)

        let bottomLeftOrigin = ScreenGeometry.flipped(topLeftOrigin, primaryScreenHeight: 1000)

        #expect(bottomLeftOrigin == CGRect(x: 50, y: 700, width: 300, height: 200))
    }

    @Test func flippingTwiceReturnsTheOriginal() {
        let rect = CGRect(x: -1200, y: -340, width: 640, height: 480)

        let once = ScreenGeometry.flipped(rect, primaryScreenHeight: 1117)
        let twice = ScreenGeometry.flipped(once, primaryScreenHeight: 1117)

        #expect(twice == rect)
    }

    @Test func handlesADisplayAboveThePrimaryOne() {
        // In top-left coordinates a display above the primary has negative y.
        let rect = CGRect(x: 0, y: -900, width: 100, height: 100)

        let flipped = ScreenGeometry.flipped(rect, primaryScreenHeight: 1000)

        #expect(flipped == CGRect(x: 0, y: 1800, width: 100, height: 100))
    }
}

@MainActor
struct WindowSelectionTests {
    // Front to back: a small window overlapping a larger one.
    private let frames = [
        CGRect(x: 100, y: 100, width: 200, height: 200),
        CGRect(x: 0, y: 0, width: 600, height: 400),
    ]

    @Test func picksTheFrontmostWindowWhereTwoOverlap() {
        let index = WindowSelectionSession.indexOfFrontmostFrame(
            at: CGPoint(x: 150, y: 150),
            in: frames
        )

        #expect(index == 0)
    }

    @Test func picksTheWindowBehindWhereOnlyItIsVisible() {
        let index = WindowSelectionSession.indexOfFrontmostFrame(
            at: CGPoint(x: 500, y: 50),
            in: frames
        )

        #expect(index == 1)
    }

    @Test func picksNothingOverTheDesktop() {
        let index = WindowSelectionSession.indexOfFrontmostFrame(
            at: CGPoint(x: 900, y: 900),
            in: frames
        )

        #expect(index == nil)
    }

    @Test func clickReportsAfterRefreshingTheHighlight() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = WindowSelectionView(frame: frame)
        window.contentView = view
        var events: [String] = []
        view.onPointerMove = { events.append("move") }
        view.onClick = { events.append("click") }

        let click = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        view.mouseDown(with: click)

        #expect(events == ["move", "click"])
    }

    @Test func showsACameraCursorWhileAreaSelectionKeepsTheCrosshair() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)

        #expect(WindowSelectionView(frame: frame).cursor === NSCursor.camera)
        #expect(AreaSelectionView(frame: frame, scale: 2).cursor === NSCursor.crosshair)
    }

    @Test func cameraCursorIsDrawnSharplyWithItsHotSpotInTheMiddle() {
        let cursor = NSCursor.camera
        let size = NSCursor.cameraCursorSize

        #expect(cursor !== NSCursor.arrow)
        #expect(cursor.image.size == size)
        #expect(cursor.hotSpot == NSPoint(x: size.width / 2, y: size.height / 2))
        let pixelWidths = cursor.image.representations.map(\.pixelsWide).sorted()
        #expect(pixelWidths == [Int(size.width), Int(size.width) * 2])
    }

    @Test func cameraSitsOnWholePointsSoItStaysSharp() {
        let origin = NSCursor.centeredOrigin(
            of: CGSize(width: 23, height: 18),
            in: CGSize(width: 28, height: 28)
        )

        #expect(origin == CGPoint(x: 2, y: 5))
    }

    @Test func focusShowsTheFocusedOverlaysCursor() throws {
        let screen = try #require(NSScreen.screens.first)
        let panel = OverlayPanel(screen: screen)
        let view = WindowSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        panel.contentView = view
        panel.makeFirstResponder(view)
        NSCursor.arrow.set()

        OverlayPanel.focus([panel])

        #expect(NSCursor.current === NSCursor.camera)
        panel.orderOut(nil)
        NSCursor.arrow.set()
    }
}

@MainActor
struct SpaceChangeObserverTests {
    @Test func callsBackOnASpaceChangeUntilStopped() async throws {
        let counter = Counter()
        let observer = SpaceChangeObserver { counter.value += 1 }

        postSpaceChange()
        try await waitUntil { counter.value == 1 }

        observer.stop()
        postSpaceChange()
        // Long enough for a call that should not come to arrive.
        try await Task.sleep(for: .milliseconds(100))
        #expect(counter.value == 1)
    }

    /// Only this test process hears it; the real Spaces are left alone.
    private func postSpaceChange() {
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    private final class Counter {
        var value = 0
    }
}
