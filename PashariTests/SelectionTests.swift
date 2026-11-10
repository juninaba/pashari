import AppKit
import Carbon.HIToolbox
import Testing

@testable import Pashari

@MainActor
struct AnnotationGeometryTests {
    @Test func boundsIncludeHalfTheStrokeOnEachSide() {
        let annotation = make(.rectangle(CGRect(x: 10, y: 10, width: 40, height: 20)), size: .medium)

        // Medium is 4 points wide: 2 outside the rectangle on every side.
        #expect(annotation.bounds == CGRect(x: 8, y: 8, width: 44, height: 24))
    }

    @Test func aLineIsHitNearItAndMissedFurtherAway() {
        let annotation = make(.line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0)))

        #expect(annotation.isHit(at: CGPoint(x: 50, y: 0)))
        #expect(annotation.isHit(at: CGPoint(x: 50, y: 5)))
        #expect(!annotation.isHit(at: CGPoint(x: 50, y: 12)))
        // Past the end of the line, not merely beside it.
        #expect(!annotation.isHit(at: CGPoint(x: 115, y: 0)))
    }

    @Test func aRectangleIsHitOnItsOutlineButNotInTheMiddle() {
        let annotation = make(.rectangle(CGRect(x: 0, y: 0, width: 100, height: 80)))

        #expect(annotation.isHit(at: CGPoint(x: 50, y: 0)))
        #expect(annotation.isHit(at: CGPoint(x: 100, y: 40)))
        #expect(!annotation.isHit(at: CGPoint(x: 50, y: 40)))
        #expect(!annotation.isHit(at: CGPoint(x: 130, y: 40)))
    }

    @Test func anEllipseIsHitOnItsOutlineButNotInTheMiddle() {
        let annotation = make(.ellipse(CGRect(x: 0, y: 0, width: 100, height: 60)))

        // Leftmost and topmost points of the outline.
        #expect(annotation.isHit(at: CGPoint(x: 0, y: 30)))
        #expect(annotation.isHit(at: CGPoint(x: 50, y: 0)))
        #expect(!annotation.isHit(at: CGPoint(x: 50, y: 30)))
        // The corner of the bounding box is well outside the curve.
        #expect(!annotation.isHit(at: CGPoint(x: 0, y: 0)))
    }

    @Test func aPenStrokeIsHitAlongItsPath() {
        let annotation = make(.pen([CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 50)]))

        #expect(annotation.isHit(at: CGPoint(x: 25, y: 2)))
        #expect(annotation.isHit(at: CGPoint(x: 52, y: 30)))
        #expect(!annotation.isHit(at: CGPoint(x: 20, y: 30)))
    }

    @Test func filledMarksAreHitAnywhereInside() {
        let blur = make(.blur(CGRect(x: 0, y: 0, width: 100, height: 80)))
        let counter = make(.counter(1, center: CGPoint(x: 200, y: 200)))
        let text = make(.text("Hello", origin: CGPoint(x: 300, y: 300)))

        #expect(blur.isHit(at: CGPoint(x: 50, y: 40)))
        #expect(counter.isHit(at: CGPoint(x: 205, y: 195)))
        #expect(text.isHit(at: CGPoint(x: 310, y: 310)))
        #expect(!text.isHit(at: CGPoint(x: 280, y: 310)))
    }

    @Test func textBoundsGrowWithEachLine() {
        let oneLine = make(.text("Hello", origin: .zero)).bounds
        let twoLines = make(.text("Hello\nworld", origin: .zero)).bounds

        #expect(twoLines.height > oneLine.height * 1.8)
    }

    @Test func movingShiftsEveryKindOfMark() {
        let offset = CGSize(width: 10, height: -5)
        let a = CGPoint(x: 1, y: 2)
        let b = CGPoint(x: 30, y: 40)
        let rect = CGRect(x: 5, y: 6, width: 20, height: 10)
        let movedA = CGPoint(x: 11, y: -3)
        let movedB = CGPoint(x: 40, y: 35)
        let movedRect = CGRect(x: 15, y: 1, width: 20, height: 10)

        let cases: [(Annotation.Shape, Annotation.Shape)] = [
            (.arrow(from: a, to: b), .arrow(from: movedA, to: movedB)),
            (.line(from: a, to: b), .line(from: movedA, to: movedB)),
            (.rectangle(rect), .rectangle(movedRect)),
            (.ellipse(rect), .ellipse(movedRect)),
            (.pen([a, b]), .pen([movedA, movedB])),
            (.highlighter([a, b]), .highlighter([movedA, movedB])),
            (.text("hi", origin: a), .text("hi", origin: movedA)),
            (.blur(rect), .blur(movedRect)),
            (.counter(3, center: a), .counter(3, center: movedA)),
        ]
        for (original, expected) in cases {
            let annotation = make(original)
            let moved = annotation.translated(by: offset)

            #expect(moved.shape == expected)
            // Still the same annotation, with the same look.
            #expect(moved.id == annotation.id)
            #expect(moved.color == annotation.color)
            #expect(moved.size == annotation.size)
        }
    }

    @Test func aClickPicksTheMarkOnTop() {
        var document = AnnotationDocument()
        let below = make(.blur(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let above = make(.counter(1, center: CGPoint(x: 50, y: 50)))
        document.annotations = [below, above]

        #expect(document.topmostAnnotation(at: CGPoint(x: 50, y: 50))?.id == above.id)
        #expect(document.topmostAnnotation(at: CGPoint(x: 10, y: 10))?.id == below.id)
        #expect(document.topmostAnnotation(at: CGPoint(x: 300, y: 300)) == nil)
    }

    @Test func aDeletedNumberIsNotHandedOutAgain() {
        var document = AnnotationDocument()
        document.annotations = [
            make(.counter(1, center: .zero)),
            make(.counter(3, center: .zero)),
        ]

        // Number 2 was deleted. Counting the badges would give 3 again.
        #expect(document.nextCounterNumber == 4)
    }

    private func make(_ shape: Annotation.Shape, size: StrokeSize = .medium) -> Annotation {
        Annotation(shape: shape, color: .red, size: size)
    }
}

@MainActor
struct EditorSelectionTests {
    @Test func selectingMovingAndDeleting() {
        let model = makeModel()
        model.add(.rectangle(CGRect(x: 10, y: 10, width: 40, height: 30)))
        model.tool = .select

        #expect(model.select(at: CGPoint(x: 10, y: 20)))
        model.moveSelected(by: CGSize(width: 5, height: 7))

        #expect(model.document.annotations.map(\.shape) == [
            .rectangle(CGRect(x: 15, y: 17, width: 40, height: 30))
        ])
        // Still selected after the move.
        #expect(model.selectedAnnotation != nil)

        model.deleteSelected()
        #expect(model.document.annotations.isEmpty)
        #expect(model.selectedID == nil)
    }

    @Test func moveAndDeleteAreEachOneUndoStep() {
        let model = makeModel()
        let original = Annotation.Shape.rectangle(CGRect(x: 10, y: 10, width: 40, height: 30))
        model.add(original)
        model.tool = .select
        model.select(at: CGPoint(x: 10, y: 20))
        model.moveSelected(by: CGSize(width: 5, height: 7))
        model.deleteSelected()

        model.undo()
        #expect(model.document.annotations.count == 1)
        model.undo()
        #expect(model.document.annotations.map(\.shape) == [original])
    }

    @Test func selectingAloneIsNotAnUndoStep() {
        let model = makeModel()
        model.tool = .select

        model.select(at: CGPoint(x: 10, y: 10))

        #expect(!model.canUndo)
    }

    @Test func clickingEmptySpaceClearsTheSelection() {
        let model = makeModel()
        model.add(.counter(1, center: CGPoint(x: 20, y: 20)))
        model.tool = .select
        model.select(at: CGPoint(x: 20, y: 20))

        #expect(!model.select(at: CGPoint(x: 90, y: 50)))
        #expect(model.selectedID == nil)
    }

    @Test func switchingToADrawingToolClearsTheSelection() {
        let model = makeModel()
        model.add(.counter(1, center: CGPoint(x: 20, y: 20)))
        model.tool = .select
        model.select(at: CGPoint(x: 20, y: 20))

        model.tool = .arrow

        #expect(model.selectedID == nil)
    }

    @Test func undoingTheSelectedMarkAwayClearsTheSelection() {
        let model = makeModel()
        model.add(.counter(1, center: CGPoint(x: 20, y: 20)))
        model.tool = .select
        model.select(at: CGPoint(x: 20, y: 20))

        model.undo()

        #expect(model.selectedID == nil)
    }

    @Test func deletingWithNothingSelectedDoesNothing() {
        let model = makeModel()
        model.add(.counter(1, center: CGPoint(x: 20, y: 20)))

        model.deleteSelected()

        #expect(model.document.annotations.count == 1)
    }
}

@MainActor
struct CanvasSelectionTests {
    @Test func draggingASelectedMarkMovesItInOneStep() {
        let harness = CanvasHarness()
        harness.model.add(.counter(1, center: CGPoint(x: 20, y: 20)))
        harness.model.tool = .select

        // Three mouse-move events, but a single change to the document.
        harness.stroke(through: [
            CGPoint(x: 20, y: 20), CGPoint(x: 30, y: 25), CGPoint(x: 45, y: 30), CGPoint(x: 60, y: 35),
        ])

        #expect(harness.shapes == [.counter(1, center: CGPoint(x: 60, y: 35))])
        harness.model.undo()
        #expect(harness.shapes == [.counter(1, center: CGPoint(x: 20, y: 20))])
    }

    @Test func clickingWithoutDraggingOnlySelects() {
        let harness = CanvasHarness()
        harness.model.add(.counter(1, center: CGPoint(x: 20, y: 20)))
        harness.model.tool = .select
        let undoStepsBefore = harness.model.canUndo

        harness.click(at: CGPoint(x: 20, y: 20))

        #expect(harness.model.selectedAnnotation != nil)
        #expect(harness.shapes == [.counter(1, center: CGPoint(x: 20, y: 20))])
        #expect(harness.model.canUndo == undoStepsBefore)
        // Nothing to redo either: the click made no change that undo undid.
        #expect(!harness.model.canRedo)
    }

    @Test func theSelectToolDoesNotDraw() {
        let harness = CanvasHarness()
        harness.model.tool = .select

        harness.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 40))

        #expect(harness.shapes.isEmpty)
    }

    @Test func theDeleteKeyRemovesTheSelectedMark() {
        let harness = CanvasHarness()
        harness.model.add(.counter(1, center: CGPoint(x: 20, y: 20)))
        harness.model.add(.counter(2, center: CGPoint(x: 70, y: 40)))
        harness.model.tool = .select
        harness.click(at: CGPoint(x: 20, y: 20))

        harness.press(keyCode: kVK_Delete)

        #expect(harness.shapes == [.counter(2, center: CGPoint(x: 70, y: 40))])
    }

    @Test func escapeClearsTheSelection() {
        let harness = CanvasHarness()
        harness.model.add(.counter(1, center: CGPoint(x: 20, y: 20)))
        harness.model.tool = .select
        harness.click(at: CGPoint(x: 20, y: 20))

        harness.press(keyCode: kVK_Escape)

        #expect(harness.model.selectedID == nil)
        #expect(harness.shapes.count == 1)
    }
}
