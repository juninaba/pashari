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

        #expect(annotation.isHit(at: CGPoint(x: 0, y: 30)))
        #expect(annotation.isHit(at: CGPoint(x: 50, y: 0)))
        #expect(!annotation.isHit(at: CGPoint(x: 50, y: 30)))
        // The corner of the bounding box is well outside the curve.
        #expect(!annotation.isHit(at: CGPoint(x: 0, y: 0)))
    }

    @Test func aLongThinEllipseIsHitOnlyNearItsOutline() {
        let annotation = make(.ellipse(CGRect(x: 0, y: 0, width: 400, height: 20)))

        #expect(annotation.isHit(at: CGPoint(x: 0, y: 10)))
        #expect(annotation.isHit(at: CGPoint(x: 200, y: 0)))
        #expect(!annotation.isHit(at: CGPoint(x: -100, y: 10)))
        #expect(!annotation.isHit(at: CGPoint(x: 450, y: 10)))
    }

    @Test func aPenStrokeIsHitWhereItsCurveIsDrawn() {
        // The pen draws a smooth curve that cuts the corner at (120, 20).
        let annotation = make(
            .pen([CGPoint(x: 20, y: 20), CGPoint(x: 120, y: 20), CGPoint(x: 120, y: 120)])
        )

        // On the curve, 12.5 points in from the corner.
        #expect(annotation.isHit(at: CGPoint(x: 95, y: 32.5)))
        // The corner itself is about 24 points away from the ink.
        #expect(!annotation.isHit(at: CGPoint(x: 120, y: 20)))
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
            (.text("hi", origin: a), .text("hi", origin: movedA)),
            (.blur(rect), .blur(movedRect)),
            (.counter(3, center: a), .counter(3, center: movedA)),
        ]
        for (original, expected) in cases {
            let annotation = make(original)
            let moved = annotation.translated(by: offset)

            #expect(moved.shape == expected)
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

    @Test func arrowsAndLinesExposeEndpointHandles() {
        let arrow = make(.arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 80, y: 50)))
        let line = make(.line(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 80, y: 50)))

        #expect(arrow.handles().map(\.handle) == [.start, .end])
        #expect(line.handles().map(\.handle) == [.start, .end])
        #expect(arrow.handle(at: CGPoint(x: 12, y: 22)) == .start)
        #expect(arrow.handle(at: CGPoint(x: 78, y: 49)) == .end)
        #expect(arrow.handle(at: CGPoint(x: 45, y: 35)) == nil)
    }

    @Test func boxMarksExposeCornerAndSideHandlesBasedOnScreenSize() {
        let large = make(.rectangle(CGRect(x: 10, y: 10, width: 60, height: 48)))
        let justAtThreshold = make(.rectangle(CGRect(x: 0, y: 0, width: 44, height: 44)))
        let belowThreshold = make(.rectangle(CGRect(x: 0, y: 0, width: 32, height: 32)))
        let wideAndThin = make(.blur(CGRect(x: 10, y: 10, width: 60, height: 14)))
        let small = make(.ellipse(CGRect(x: 10, y: 10, width: 16, height: 14)))

        #expect(Set(large.handles().map(\.handle)) == [
            .topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left,
        ])
        // Just at the side-handle threshold, a stroke point midway between corner
        // and side handles remains free to move the box.
        #expect(Set(justAtThreshold.handles().map(\.handle)) == [
            .topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left,
        ])
        #expect(justAtThreshold.isHit(at: CGPoint(x: 11, y: 0)))
        #expect(justAtThreshold.handle(at: CGPoint(x: 11, y: 0)) == nil)

        // Below the threshold, side handles are omitted so the stroke stays easy to grab.
        #expect(Set(belowThreshold.handles().map(\.handle)) == [
            .topLeft, .topRight, .bottomRight, .bottomLeft,
        ])
        #expect(belowThreshold.handle(at: CGPoint(x: 16, y: 0)) == nil)

        // When the short side leaves no room between opposite edge handles, only corners appear.
        #expect(Set(wideAndThin.handles().map(\.handle)) == [
            .topLeft, .topRight, .bottomRight, .bottomLeft,
        ])
        #expect(Set(small.handles().map(\.handle)) == [
            .topLeft, .topRight, .bottomRight, .bottomLeft,
        ])
        // Zooming in gives the small ellipse enough room on screen for side handles too.
        #expect(Set(small.handles(magnification: 4).map(\.handle)) == [
            .topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left,
        ])
    }

    @Test func handleHitReachAdaptsToZoomMagnification() {
        let arrow = make(.arrow(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 80, y: 20)))

        // 12 image points away is outside the 1x hit radius (7 pt), but inside at 0.5x (14 image pt).
        #expect(arrow.handle(at: CGPoint(x: 92, y: 20), magnification: 1) == nil)
        #expect(arrow.handle(at: CGPoint(x: 92, y: 20), magnification: 0.5) == .end)

        // 5 image points away is inside at 1x, but outside at 4x (1.75 image pt).
        #expect(arrow.handle(at: CGPoint(x: 85, y: 20), magnification: 1) == .end)
        #expect(arrow.handle(at: CGPoint(x: 85, y: 20), magnification: 4) == nil)

        // A 40 pt line at 0.1x keeps its outer visible handle reachable (3 screen pt = 30 image pt outside)
        // while yielding the middle to move drags.
        let shortLine = make(.line(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 60, y: 20)))
        #expect(shortLine.handle(at: CGPoint(x: -10, y: 20), magnification: 0.1) == .start)
        #expect(shortLine.handle(at: CGPoint(x: 90, y: 20), magnification: 0.1) == .end)
        #expect(shortLine.handle(at: CGPoint(x: 40, y: 20), magnification: 0.1) == nil)

        // A wide, thin blur at 0.1x omits opposite edge handles and keeps its centre free to move.
        let thinBlur = make(.blur(CGRect(x: 0, y: 0, width: 400, height: 30)))
        #expect(thinBlur.handle(at: CGPoint(x: 200, y: 15), magnification: 0.1) == nil)
        #expect(thinBlur.handle(at: CGPoint(x: -30, y: 0), magnification: 0.1) == .topLeft)
    }

    @Test func nonResizableMarksHaveNoHandles() {
        let pen = make(.pen([CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 30)]))
        let text = make(.text("Hello", origin: CGPoint(x: 10, y: 10)))
        let counter = make(.counter(1, center: CGPoint(x: 20, y: 20)))

        #expect(pen.handles().isEmpty)
        #expect(text.handles().isEmpty)
        #expect(counter.handles().isEmpty)
    }

    @Test func resizingArrowAndLineEndpointsMovesOnlyTheDraggedEnd() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 60)
        let arrow = make(.arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 60, y: 20)))

        let movedStart = arrow.resized(dragging: .start, to: CGPoint(x: 20, y: 50), within: bounds)
        #expect(movedStart.shape == .arrow(from: CGPoint(x: 20, y: 50), to: CGPoint(x: 60, y: 20)))

        let movedEnd = arrow.resized(dragging: .end, to: CGPoint(x: 5, y: 40), within: bounds)
        #expect(movedEnd.shape == .arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 5, y: 40)))

        // Shift snaps the dragged endpoint in 45° steps around the fixed end.
        let snappedEnd = arrow.resized(dragging: .end, to: CGPoint(x: 80, y: 25), constrained: true, within: bounds)
        #expect(snappedEnd.shape == .arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 80, y: 20)))

        let snappedStart = arrow.resized(dragging: .start, to: CGPoint(x: 57, y: 50), constrained: true, within: bounds)
        #expect(snappedStart.shape == .arrow(from: CGPoint(x: 60, y: 50), to: CGPoint(x: 60, y: 20)))

        // When the fixed end sits outside a cropped view, a snap that would pull the
        // dragged end out of bounds falls back to the clamped pointer instead of vanishing.
        let cropped = CGRect(x: 50, y: 0, width: 100, height: 100)
        let croppedLine = make(.line(from: CGPoint(x: 39, y: 10), to: CGPoint(x: 90, y: 10)))
        let verticalFallback = croppedLine.resized(
            dragging: .end,
            to: CGPoint(x: 55, y: 80),
            constrained: true,
            within: cropped
        )
        #expect(verticalFallback.shape == .line(from: CGPoint(x: 39, y: 10), to: CGPoint(x: 55, y: 80)))
        // A snap whose dragged end stays inside the crop still snaps cleanly.
        let horizontalSnap = croppedLine.resized(
            dragging: .end,
            to: CGPoint(x: 110, y: 14),
            constrained: true,
            within: cropped
        )
        #expect(horizontalSnap.shape == .line(from: CGPoint(x: 39, y: 10), to: CGPoint(x: 110, y: 10)))
    }

    @Test func resizingBoxMarksAdjustsEdgesCornersAndMinimumSize() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 60)
        let rect = make(.rectangle(CGRect(x: 20, y: 10, width: 40, height: 30)))

        #expect(
            rect.resized(dragging: .right, to: CGPoint(x: 80, y: 25), within: bounds).shape
                == .rectangle(CGRect(x: 20, y: 10, width: 60, height: 30))
        )
        #expect(
            rect.resized(dragging: .topLeft, to: CGPoint(x: 10, y: 5), within: bounds).shape
                == .rectangle(CGRect(x: 10, y: 5, width: 50, height: 35))
        )
        // Dragging past the opposite edge clamps at the minimum side length.
        #expect(
            rect.resized(dragging: .left, to: CGPoint(x: 90, y: 25), within: bounds).shape
                == .rectangle(CGRect(x: 57, y: 10, width: 3, height: 30))
        )

        // Shift on a rectangle or ellipse corner constrains to a square/circle inside bounds.
        let square = rect.resized(dragging: .bottomRight, to: CGPoint(x: 70, y: 25), constrained: true, within: bounds)
        #expect(square.shape == .rectangle(CGRect(x: 20, y: 10, width: 50, height: 50)))

        let ellipse = make(.ellipse(CGRect(x: 20, y: 10, width: 40, height: 30)))
        let circle = ellipse.resized(dragging: .topLeft, to: CGPoint(x: 30, y: 20), constrained: true, within: bounds)
        #expect(circle.shape == .ellipse(CGRect(x: 30, y: 10, width: 30, height: 30)))

        // Blur stays unconstrained even with Shift.
        let blur = make(.blur(CGRect(x: 20, y: 10, width: 40, height: 30)))
        let resizedBlur = blur.resized(dragging: .bottomRight, to: CGPoint(x: 75, y: 30), constrained: true, within: bounds)
        #expect(resizedBlur.shape == .blur(CGRect(x: 20, y: 10, width: 55, height: 20)))
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

    @Test func changingColourAndSizeRestylesTheSelectedMarkWithUndoAndRedo() {
        let model = makeModel()
        model.color = .red
        model.size = .small
        model.add(.arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 80, y: 20)))
        model.color = .blue
        model.size = .large

        model.tool = .select
        #expect(model.displayedColor == .blue)
        #expect(model.displayedSize == .large)
        #expect(model.canEditStyle)

        #expect(model.select(at: CGPoint(x: 40, y: 20)))
        #expect(model.displayedColor == .red)
        #expect(model.displayedSize == .small)
        #expect(model.canEditStyle)

        model.chooseColor(.green)
        model.chooseSize(.large)
        #expect(model.selectedAnnotation?.color == .green)
        #expect(model.selectedAnnotation?.size == .large)
        #expect(model.displayedColor == .green)
        #expect(model.displayedSize == .large)

        // Picking the same colour again does not add a redundant undo step.
        model.chooseColor(.green)

        model.undo()
        #expect(model.selectedAnnotation?.size == .small)
        #expect(model.displayedSize == .small)
        #expect(model.selectedAnnotation?.color == .green)

        model.undo()
        #expect(model.selectedAnnotation?.color == .red)
        #expect(model.displayedColor == .red)

        model.redo()
        #expect(model.selectedAnnotation?.color == .green)
        #expect(model.displayedColor == .green)
    }

    @Test func styleChangesWorkAcrossAllStyledShapes() {
        let shapes: [Annotation.Shape] = [
            .arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 60, y: 20)),
            .line(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 60, y: 20)),
            .rectangle(CGRect(x: 10, y: 10, width: 40, height: 30)),
            .ellipse(CGRect(x: 10, y: 10, width: 40, height: 30)),
            .pen([CGPoint(x: 10, y: 20), CGPoint(x: 60, y: 20)]),
            .text("Hi", origin: CGPoint(x: 10, y: 10)),
            .counter(1, center: CGPoint(x: 30, y: 30)),
        ]
        let hitPoints: [CGPoint] = [
            CGPoint(x: 35, y: 20),
            CGPoint(x: 35, y: 20),
            CGPoint(x: 10, y: 20),
            CGPoint(x: 10, y: 25),
            CGPoint(x: 35, y: 20),
            CGPoint(x: 15, y: 15),
            CGPoint(x: 30, y: 30),
        ]

        for (shape, hitPoint) in zip(shapes, hitPoints) {
            let model = makeModel()
            model.color = .red
            model.size = .small
            model.add(shape)
            model.tool = .select
            #expect(model.select(at: hitPoint))

            model.chooseColor(.yellow)
            model.chooseSize(.large)

            let updated = model.selectedAnnotation
            #expect(updated?.color == .yellow)
            #expect(updated?.size == .large)
            #expect(updated?.shape == shape)
        }
    }

    @Test func selectingABlurDisablesStyleEditingWithoutMutatingIt() {
        let model = makeModel()
        model.color = .blue
        model.size = .large
        model.add(.blur(CGRect(x: 10, y: 10, width: 40, height: 30)))
        model.tool = .select

        #expect(model.select(at: CGPoint(x: 30, y: 25)))
        #expect(!model.canEditStyle)
        #expect(model.displayedColor == nil)
        #expect(model.displayedSize == nil)

        let before = model.document
        model.chooseColor(.green)
        model.chooseSize(.small)

        #expect(model.document == before)
        #expect(model.color == .blue)
        #expect(model.size == .large)

        // Deselecting restores the toolbar's default drawing style.
        model.deselect()
        #expect(model.canEditStyle)
        #expect(model.displayedColor == .blue)
        #expect(model.displayedSize == .large)
    }

    @Test func updatingShapeIsOneUndoStepAndPreservesOrder() {
        let model = makeModel()
        model.add(.rectangle(CGRect(x: 10, y: 10, width: 30, height: 20)))
        model.add(.counter(1, center: CGPoint(x: 80, y: 40)))
        let firstID = model.document.annotations[0].id
        model.tool = .select
        model.select(at: CGPoint(x: 10, y: 20))

        model.updateSelectedShape(.rectangle(CGRect(x: 10, y: 10, width: 50, height: 35)))

        #expect(model.document.annotations[0].id == firstID)
        #expect(model.document.annotations[0].shape == .rectangle(CGRect(x: 10, y: 10, width: 50, height: 35)))
        model.undo()
        #expect(model.document.annotations[0].shape == .rectangle(CGRect(x: 10, y: 10, width: 30, height: 20)))
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

    @Test func draggingAnArrowHandleResizesItInOneUndoStep() {
        let harness = CanvasHarness()
        harness.model.add(.arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 60, y: 20)))
        harness.model.tool = .select
        harness.click(at: CGPoint(x: 35, y: 20))

        harness.stroke(through: [
            CGPoint(x: 60, y: 20), CGPoint(x: 70, y: 30), CGPoint(x: 80, y: 45),
        ])

        #expect(harness.shapes == [.arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 80, y: 45))])
        harness.model.undo()
        #expect(harness.shapes == [.arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 60, y: 20))])
    }

    @Test func draggingALineHandleWithShiftSnapsTo45Degrees() {
        let harness = CanvasHarness()
        harness.model.add(.line(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 50, y: 20)))
        harness.model.tool = .select
        harness.click(at: CGPoint(x: 30, y: 20))

        harness.drag(from: CGPoint(x: 50, y: 20), to: CGPoint(x: 70, y: 25), modifiers: .shift)

        #expect(harness.shapes == [.line(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 70, y: 20))])
    }

    @Test func draggingAnArrowHandleTooCloseToTheOtherEndKeepsTheOriginal() {
        let harness = CanvasHarness()
        harness.model.add(.arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 60, y: 20)))
        harness.model.tool = .select
        harness.click(at: CGPoint(x: 35, y: 20))

        harness.drag(from: CGPoint(x: 60, y: 20), to: CGPoint(x: 11, y: 20))

        #expect(harness.shapes == [.arrow(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 60, y: 20))])
    }

    @Test func draggingRectangleEllipseAndBlurHandlesResizesThemInOneStep() {
        let harness = CanvasHarness()
        harness.model.add(.rectangle(CGRect(x: 10, y: 10, width: 40, height: 30)))
        harness.model.tool = .select
        harness.click(at: CGPoint(x: 10, y: 20))

        // Drag bottom-right corner with Shift -> square.
        harness.drag(from: CGPoint(x: 50, y: 40), to: CGPoint(x: 60, y: 30), modifiers: .shift)
        #expect(harness.shapes == [.rectangle(CGRect(x: 10, y: 10, width: 50, height: 50))])
        harness.model.undo()
        #expect(harness.shapes == [.rectangle(CGRect(x: 10, y: 10, width: 40, height: 30))])

        // Ellipse corner handle is outside its stroke, yet grabbing it resizes instead of deselecting.
        let ellipseHarness = CanvasHarness()
        ellipseHarness.model.add(.ellipse(CGRect(x: 10, y: 10, width: 40, height: 30)))
        ellipseHarness.model.tool = .select
        ellipseHarness.click(at: CGPoint(x: 10, y: 25))
        #expect(ellipseHarness.model.selectedAnnotation != nil)
        ellipseHarness.drag(from: CGPoint(x: 50, y: 40), to: CGPoint(x: 80, y: 50))
        #expect(ellipseHarness.shapes == [.ellipse(CGRect(x: 10, y: 10, width: 70, height: 40))])

        // Blur side handle (edge >= 44 screen pt so side handles are present).
        let blurHarness = CanvasHarness()
        blurHarness.model.add(.blur(CGRect(x: 10, y: 8, width: 46, height: 44)))
        blurHarness.model.tool = .select
        blurHarness.click(at: CGPoint(x: 33, y: 30))
        blurHarness.drag(from: CGPoint(x: 56, y: 30), to: CGPoint(x: 80, y: 30))
        #expect(blurHarness.shapes == [.blur(CGRect(x: 10, y: 8, width: 70, height: 44))])
    }

    @Test func handlesStayGrabbableWhenZoomedOutInAScrollView() throws {
        let editor = AnnotationEditorWindowController(screenshot: makeScreenshot())
        editor.onClose = nil
        editor.model.add(.arrow(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 60, y: 20)))
        editor.model.tool = .select
        editor.model.select(at: CGPoint(x: 40, y: 20))

        let scrollView = try #require(
            editor.window.contentView?.subviews.first { $0 is NSScrollView } as? NSScrollView
        )
        scrollView.magnification = 0.5
        editor.window.layoutIfNeeded()

        func mouse(_ type: NSEvent.EventType, at canvasPoint: CGPoint) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type,
                    location: editor.canvas.convert(canvasPoint, to: nil),
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: editor.window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
            )
        }

        // 10 image points past the tip is 5 screen points at 0.5x magnification:
        // inside the 7-point screen hit radius. Dragging by (+15, +20) shifts the
        // tip by that exact delta rather than jumping by the off-centre grab offset.
        editor.canvas.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 70, y: 20)))
        editor.canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 85, y: 40)))
        editor.canvas.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 85, y: 40)))

        #expect(editor.model.document.annotations.map(\.shape) == [
            .arrow(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 75, y: 40)),
        ])
    }

    @Test func aShortLineCanStillBeMovedFromItsMiddleWhenZoomedOut() throws {
        let editor = AnnotationEditorWindowController(screenshot: makeScreenshot())
        editor.onClose = nil
        editor.model.add(.line(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 60, y: 20)))
        editor.model.tool = .select
        editor.model.select(at: CGPoint(x: 40, y: 20))

        let scrollView = try #require(
            editor.window.contentView?.subviews.first { $0 is NSScrollView } as? NSScrollView
        )
        scrollView.magnification = 0.1
        editor.window.layoutIfNeeded()

        func mouse(_ type: NSEvent.EventType, at canvasPoint: CGPoint) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type,
                    location: editor.canvas.convert(canvasPoint, to: nil),
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: editor.window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
            )
        }

        // At 0.1x, dragging the midpoint moves the whole line rather than grabbing an endpoint.
        editor.canvas.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 40, y: 20)))
        editor.canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 50, y: 35)))
        editor.canvas.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 50, y: 35)))

        #expect(editor.model.document.annotations.map(\.shape) == [
            .line(from: CGPoint(x: 30, y: 35), to: CGPoint(x: 70, y: 35)),
        ])
    }

    @Test func releasingOrPressingShiftBeforeMouseUpUpdatesPreviewAndCommit() throws {
        let harness = CanvasHarness()
        harness.model.color = .white
        harness.model.size = .large
        harness.model.add(.line(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 50, y: 20)))
        harness.model.tool = .select
        harness.click(at: CGPoint(x: 30, y: 20))

        func mouse(_ type: NSEvent.EventType, at point: CGPoint, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type,
                    location: harness.canvas.convert(point, to: nil),
                    modifierFlags: modifiers,
                    timestamp: 0,
                    windowNumber: harness.window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
            )
        }

        func renderedPixel(at point: CGPoint) throws -> TestImages.RGBA {
            let bounds = harness.canvas.bounds
            let width = Int(bounds.width)
            let height = Int(bounds.height)
            let context = try #require(
                CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            )
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            harness.canvas.draw(bounds)
            NSGraphicsContext.restoreGraphicsState()
            let image = try #require(context.makeImage())
            return TestImages.pixel(of: image, x: Int(point.x), y: Int(point.y))
        }

        // Drag with Shift held -> preview snaps horizontally; releasing Shift before mouseUp
        // updates the preview immediately to the unsnapped diagonal.
        harness.canvas.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 50, y: 20), modifiers: []))
        harness.canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 70, y: 34), modifiers: .shift))
        #expect(try renderedPixel(at: CGPoint(x: 68, y: 33)) == .blue)

        let releaseShift = try #require(
            NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: harness.window.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56
            )
        )
        harness.canvas.flagsChanged(with: releaseShift)
        #expect(try renderedPixel(at: CGPoint(x: 68, y: 33)) != .blue)

        harness.canvas.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 70, y: 34), modifiers: []))
        #expect(harness.shapes == [.line(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 70, y: 34))])

        // Drag without Shift, then press Shift before mouseUp -> preview snaps horizontally
        // immediately before release.
        harness.canvas.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 70, y: 34), modifiers: []))
        harness.canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 80, y: 36), modifiers: []))
        #expect(try renderedPixel(at: CGPoint(x: 76, y: 35)) != .blue)

        let pressShift = try #require(
            NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: .shift, timestamp: 0,
                windowNumber: harness.window.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56
            )
        )
        harness.canvas.flagsChanged(with: pressShift)
        #expect(try renderedPixel(at: CGPoint(x: 76, y: 35)) == .blue)
        #expect(try renderedPixel(at: CGPoint(x: 76, y: 20)) != .blue)

        harness.canvas.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 80, y: 36), modifiers: .shift))
        #expect(harness.shapes == [.line(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 80, y: 20))])
    }
}
