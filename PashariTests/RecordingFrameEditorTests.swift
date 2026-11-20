import CoreGraphics
import Testing

@testable import Pashari

struct RecordingFrameEditorTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let frame = CGRect(x: 100, y: 100, width: 300, height: 200)

    private func editor(_ rect: CGRect? = nil, on screen: Int = 0) -> RecordingFrameEditor {
        RecordingFrameEditor(frame: .init(screen: screen, rect: rect ?? frame))
    }

    private func drag(
        _ editor: inout RecordingFrameEditor,
        from start: CGPoint,
        to end: CGPoint,
        on screen: Int = 0
    ) {
        editor.begin(at: start, on: screen, in: bounds)
        editor.move(to: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2))
        editor.move(to: end)
        editor.end()
    }

    @Test func aDragOutsideTheFrameDrawsANewOneOnWholePoints() {
        var editor = editor()

        drag(&editor, from: CGPoint(x: 700, y: 650), to: CGPoint(x: 500.4, y: 400.6))

        #expect(editor.frame == .init(screen: 0, rect: CGRect(x: 500, y: 401, width: 200, height: 249)))
    }

    @Test func aClickOutsideTheFrameKeepsIt() {
        var editor = editor()

        editor.begin(at: CGPoint(x: 700, y: 650), on: 0, in: bounds)
        editor.end()

        #expect(editor.frame == .init(screen: 0, rect: frame))
    }

    @Test func aFrameDrawnTooSmallToBeMeantGivesWayToTheOneBefore() {
        var editor = editor()

        drag(&editor, from: CGPoint(x: 700, y: 650), to: CGPoint(x: 710, y: 700))

        #expect(editor.frame == .init(screen: 0, rect: frame))
    }

    @Test func aFrameDrawnOnAnotherScreenMovesThereUnlessItIsTooSmall() {
        var editor = editor()

        drag(&editor, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 12, y: 12), on: 1)
        #expect(editor.frame == .init(screen: 0, rect: frame))

        drag(&editor, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 210, y: 110), on: 1)
        #expect(editor.frame == .init(screen: 1, rect: CGRect(x: 10, y: 10, width: 200, height: 100)))
    }

    @Test func aDragInsideMovesTheFrameAsFarAsTheScreenGoes() {
        var editor = editor()

        drag(&editor, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 250, y: 230))
        #expect(editor.frame?.rect == CGRect(x: 150, y: 130, width: 300, height: 200))

        drag(&editor, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 2000, y: -500))
        #expect(editor.frame?.rect == CGRect(x: 700, y: 0, width: 300, height: 200))
    }

    @Test func aCornerMovesItsTwoEdgesAndTheOppositeCornerStays() {
        var editor = editor()

        drag(&editor, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 60, y: 140))

        #expect(editor.frame?.rect == CGRect(x: 60, y: 140, width: 340, height: 160))
    }

    @Test func anEdgeMovesOnlyItself() {
        var editor = editor()

        drag(&editor, from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 600))

        #expect(editor.frame?.rect == CGRect(x: 100, y: 100, width: 400, height: 200))
    }

    @Test func aFrameCannotBeMadeSmallerThanTheSmallestFrame() {
        var editor = editor()

        drag(&editor, from: CGPoint(x: 400, y: 300), to: CGPoint(x: 0, y: 0))

        #expect(editor.frame?.rect == CGRect(x: 100, y: 100, width: 16, height: 16))
    }

    @Test func aCornerStaysOnTheScreen() {
        var editor = editor()

        drag(&editor, from: CGPoint(x: 400, y: 300), to: CGPoint(x: 1500, y: 1500))

        #expect(editor.frame?.rect == CGRect(x: 100, y: 100, width: 900, height: 700))
    }

    @Test func pressesNearTheFrameTakeHoldOfItsCornersAndEdges() {
        let editor = editor()

        #expect(editor.region(at: CGPoint(x: 92, y: 108), on: 0) == .handle(.topLeft))
        #expect(editor.region(at: CGPoint(x: 405, y: 305), on: 0) == .handle(.bottomRight))
        #expect(editor.region(at: CGPoint(x: 250, y: 96), on: 0) == .handle(.top))
        #expect(editor.region(at: CGPoint(x: 250, y: 303), on: 0) == .handle(.bottom))
        #expect(editor.region(at: CGPoint(x: 104, y: 200), on: 0) == .handle(.left))
        #expect(editor.region(at: CGPoint(x: 398, y: 200), on: 0) == .handle(.right))
        #expect(editor.region(at: CGPoint(x: 250, y: 200), on: 0) == .inside)
        #expect(editor.region(at: CGPoint(x: 600, y: 600), on: 0) == .outside)
        #expect(editor.region(at: CGPoint(x: 250, y: 200), on: 1) == .outside)
    }

    @Test func theMiddleOfASmallFrameStillMovesIt() {
        let editor = editor(CGRect(x: 100, y: 100, width: 16, height: 16))

        #expect(editor.region(at: CGPoint(x: 108, y: 108), on: 0) == .inside)
        #expect(editor.region(at: CGPoint(x: 108, y: 100), on: 0) == .handle(.top))
        #expect(editor.region(at: CGPoint(x: 101, y: 101), on: 0) == .handle(.topLeft))
    }

    @Test func withoutAFrameEveryDragDrawsOne() {
        var editor = RecordingFrameEditor()
        #expect(editor.region(at: CGPoint(x: 10, y: 10), on: 0) == .outside)

        drag(&editor, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 60))

        #expect(editor.frame == .init(screen: 0, rect: CGRect(x: 10, y: 10, width: 100, height: 50)))
    }
}
