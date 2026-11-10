import AppKit
import Testing

@testable import Pashari

/// Holding Shift while dragging: lines snap to 45-degree steps, rectangles
/// and ellipses become squares and circles.
@MainActor
struct ShiftConstraintTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    private let start = CGPoint(x: 500, y: 500)

    @Test func anAlmostHorizontalLineBecomesHorizontal() {
        let end = EditorTool.line.constrainedEnd(
            from: start,
            to: CGPoint(x: 700, y: 512),
            within: bounds
        )

        #expect(end == CGPoint(x: 700, y: 500))
    }

    @Test func anAlmostVerticalArrowBecomesVertical() {
        let end = EditorTool.arrow.constrainedEnd(
            from: start,
            to: CGPoint(x: 490, y: 300),
            within: bounds
        )

        #expect(end == CGPoint(x: 500, y: 300))
    }

    @Test func aRoughlyDiagonalLineSnapsTo45Degrees() {
        let end = EditorTool.line.constrainedEnd(
            from: start,
            to: CGPoint(x: 600, y: 620),
            within: bounds
        )

        // On the diagonal, both offsets are the same size.
        #expect(abs((end.x - 500) - (end.y - 500)) < 0.0001)
        #expect(end.x > 600 && end.x < 620)
    }

    @Test func linesSnapInAllEightDirections() {
        // One drag aimed 10 degrees off each of the eight directions.
        for step in 0..<8 {
            let exact = CGFloat(step) * .pi / 4
            let rough = exact + 10 * .pi / 180
            let pointer = CGPoint(x: 500 + cos(rough) * 200, y: 500 + sin(rough) * 200)

            let end = EditorTool.line.constrainedEnd(from: start, to: pointer, within: bounds)

            let angle = atan2(end.y - 500, end.x - 500)
            // Compare directions as vectors, which sidesteps -180 vs 180.
            #expect(abs(cos(angle) - cos(exact)) < 0.0001)
            #expect(abs(sin(angle) - sin(exact)) < 0.0001)
        }
    }

    @Test func aRectangleBecomesASquareOnItsLongerSide() {
        let end = EditorTool.rectangle.constrainedEnd(
            from: start,
            to: CGPoint(x: 700, y: 560),
            within: bounds
        )

        #expect(end == CGPoint(x: 700, y: 700))
    }

    @Test func aSquareFollowsTheDirectionOfTheDrag() {
        // Dragging up and to the left.
        let end = EditorTool.ellipse.constrainedEnd(
            from: start,
            to: CGPoint(x: 440, y: 350),
            within: bounds
        )

        #expect(end == CGPoint(x: 350, y: 350))
    }

    @Test func aSquareStopsAtTheEdgeOfTheImage() {
        let nearCorner = CGPoint(x: 950, y: 500)

        let end = EditorTool.rectangle.constrainedEnd(
            from: nearCorner,
            to: CGPoint(x: 990, y: 800),
            within: bounds
        )

        // Only 50 points of room to the right, so the square is 50 wide.
        #expect(end == CGPoint(x: 1000, y: 550))
    }

    @Test func aSnappedLineStopsAtTheEdgeOfTheImage() {
        let end = EditorTool.line.constrainedEnd(
            from: CGPoint(x: 950, y: 500),
            to: CGPoint(x: 1400, y: 510),
            within: bounds
        )

        #expect(end == CGPoint(x: 1000, y: 500))
    }

    @Test func otherToolsAreNotConstrained() {
        let pointer = CGPoint(x: 700, y: 560)

        for tool in [EditorTool.select, .pen, .highlighter, .text, .counter, .blur, .crop] {
            #expect(tool.constrainedEnd(from: start, to: pointer, within: bounds) == pointer)
        }
    }

    @Test func draggingWithShiftOnTheCanvasDrawsAStraightLine() {
        let harness = CanvasHarness()
        harness.model.tool = .line

        harness.drag(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 70, y: 26), modifiers: .shift)

        #expect(harness.shapes == [.line(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 70, y: 20))])
    }

    @Test func draggingWithoutShiftIsLeftAsDrawn() {
        let harness = CanvasHarness()
        harness.model.tool = .line

        harness.drag(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 70, y: 26))

        #expect(harness.shapes == [.line(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 70, y: 26))])
    }

    @Test func draggingWithShiftOnTheCanvasDrawsASquare() {
        let harness = CanvasHarness()
        harness.model.tool = .rectangle

        harness.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 22), modifiers: .shift)

        #expect(harness.shapes == [.rectangle(CGRect(x: 10, y: 10, width: 30, height: 30))])
    }
}
