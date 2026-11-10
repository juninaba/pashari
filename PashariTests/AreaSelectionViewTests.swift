import AppKit
import Carbon.HIToolbox
import Testing

@testable import Pashari

/// Drives the selection view with hand-made mouse and key events. The events
/// are passed straight to the view; nothing is posted to the system.
@MainActor
struct AreaSelectionViewTests {
    @Test func draggingReportsTheRectangle() {
        let harness = Harness()

        harness.drag(from: CGPoint(x: 40, y: 30), to: CGPoint(x: 140, y: 90))

        #expect(harness.results == [CGRect(x: 40, y: 30, width: 100, height: 60)])
    }

    @Test func draggingBackwardsGivesTheSameRectangle() {
        let harness = Harness()

        harness.drag(from: CGPoint(x: 140, y: 90), to: CGPoint(x: 40, y: 30))

        #expect(harness.results == [CGRect(x: 40, y: 30, width: 100, height: 60)])
    }

    @Test func selectionIsSnappedToWholePixels() {
        let harness = Harness(scale: 2)

        harness.drag(from: CGPoint(x: 10.2, y: 10.3), to: CGPoint(x: 50.6, y: 40.8))

        // At 2 pixels per point, positions land on multiples of 0.5.
        #expect(harness.results == [CGRect(x: 10, y: 10.5, width: 40.5, height: 30.5)])
    }

    @Test func selectionStopsAtTheEdgeOfTheScreen() {
        let harness = Harness()

        harness.drag(from: CGPoint(x: 350, y: 250), to: CGPoint(x: 900, y: 900))

        #expect(harness.results == [CGRect(x: 350, y: 250, width: 50, height: 50)])
    }

    @Test func clickWithoutDraggingKeepsTheOverlayOpen() {
        let harness = Harness()

        harness.drag(from: CGPoint(x: 40, y: 30), to: CGPoint(x: 40, y: 30))

        #expect(harness.results.isEmpty)
    }

    @Test func escapeCancels() {
        let harness = Harness()

        harness.pressEscape()

        #expect(harness.results == [nil])
    }

    @Test func rightClickCancels() {
        let harness = Harness()

        harness.view.rightMouseDown(with: harness.mouseEvent(.rightMouseDown, at: CGPoint(x: 5, y: 5)))

        #expect(harness.results == [nil])
    }
}

/// A selection view inside an off-screen window, plus a record of what it
/// reported.
@MainActor
private final class Harness {
    let window: NSWindow
    let view: AreaSelectionView
    private(set) var results: [CGRect?] = []

    init(scale: CGFloat = 1) {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        view = AreaSelectionView(frame: frame, scale: scale)
        window.contentView = view
        view.onFinish = { [weak self] rect in self?.results.append(rect) }
    }

    /// `from` and `to` are in the view's coordinates (origin top-left).
    func drag(from: CGPoint, to: CGPoint) {
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: from))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: to))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: to))
    }

    func pressEscape() {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: UInt16(kVK_Escape)
        )!
        view.keyDown(with: event)
    }

    func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: view.convert(point, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
}
