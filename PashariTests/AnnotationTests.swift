import CoreGraphics
import Foundation
import Testing

@testable import Pashari

@MainActor
struct HistoryTests {
    @Test func undoAndRedoMoveBetweenStates() {
        var history = History("a")
        history.apply("b")
        history.apply("c")

        history.undo()
        #expect(history.current == "b")
        history.undo()
        #expect(history.current == "a")
        #expect(!history.canUndo)

        history.redo()
        #expect(history.current == "b")
        history.redo()
        #expect(history.current == "c")
        #expect(!history.canRedo)
    }

    @Test func aNewChangeDiscardsWhatCouldBeRedone() {
        var history = History("a")
        history.apply("b")
        history.undo()

        history.apply("c")

        #expect(!history.canRedo)
        history.undo()
        #expect(history.current == "a")
    }

    @Test func applyingTheSameStateIsNotAStep() {
        var history = History("a")

        history.apply("a")

        #expect(!history.canUndo)
    }

    @Test func undoAndRedoWithNothingToDoAreHarmless() {
        var history = History("a")

        history.undo()
        history.redo()

        #expect(history.current == "a")
    }
}

@MainActor
struct AnnotationDocumentTests {
    @Test func countersAreNumberedInOrder() {
        var document = AnnotationDocument()
        #expect(document.nextCounterNumber == 1)

        document.annotations.append(make(.counter(1, center: .zero)))
        document.annotations.append(make(.rectangle(CGRect(x: 0, y: 0, width: 5, height: 5))))
        document.annotations.append(make(.counter(2, center: .zero)))

        #expect(document.nextCounterNumber == 3)
    }

    @Test func emptyMeansNoAnnotationsAndNoCrop() {
        var document = AnnotationDocument()
        #expect(document.isEmpty)

        document.cropRect = CGRect(x: 0, y: 0, width: 10, height: 10)
        #expect(!document.isEmpty)
    }

    private func make(_ shape: Annotation.Shape) -> Annotation {
        Annotation(shape: shape, color: .red, size: .medium)
    }
}

@MainActor
struct AnnotationRendererTests {
    @Test func arrowHeadPointsBackAlongTheArrow() {
        let head = AnnotationRenderer.arrowHead(
            from: CGPoint(x: 0, y: 50),
            to: CGPoint(x: 100, y: 50),
            lineWidth: 4
        )

        // The head is 18 long (4.5 times the line width) and symmetric.
        #expect(head.base == CGPoint(x: 82, y: 50))
        #expect(head.left.x == 82)
        #expect(head.right.x == 82)
        #expect(abs((head.left.y - 50) + (head.right.y - 50)) < 0.0001)
        #expect(abs(abs(head.left.y - 50) - 8.1) < 0.0001)
    }

    @Test func arrowHeadIsNoLongerThanAShortArrow() {
        let head = AnnotationRenderer.arrowHead(
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 5, y: 0),
            lineWidth: 4
        )

        #expect(head.base == CGPoint(x: 0, y: 0))
    }

    @Test func flattenWithoutChangesKeepsTheImage() throws {
        let image = TestImages.make(
            width: 200,
            height: 120,
            patchRect: CGRect(x: 20, y: 10, width: 40, height: 20)
        )
        let screenshot = Screenshot(image: image, scale: 2, capturedAt: Date())

        let result = try AnnotationRenderer.flatten(
            screenshot,
            with: AnnotationDocument(),
            blurredImage: nil
        )

        #expect(result.image.width == 200)
        #expect(result.image.height == 120)
        #expect(result.scale == 2)
        // The red patch is still in the top-left area, not mirrored.
        #expect(TestImages.pixel(of: result.image, x: 30, y: 15) == .red)
        #expect(TestImages.pixel(of: result.image, x: 30, y: 100) == .blue)
    }

    @Test func flattenDrawsAnnotationsAtFullResolution() throws {
        let screenshot = Screenshot(
            image: TestImages.make(width: 200, height: 120),
            scale: 2,
            capturedAt: Date()
        )
        var document = AnnotationDocument()
        // A thick horizontal line at y = 30 points, so y = 60 pixels.
        document.annotations.append(
            Annotation(
                shape: .line(from: CGPoint(x: 10, y: 30), to: CGPoint(x: 90, y: 30)),
                color: .white,
                size: .large
            )
        )

        let result = try AnnotationRenderer.flatten(screenshot, with: document, blurredImage: nil)

        let white = TestImages.RGBA(red: 255, green: 255, blue: 255, alpha: 255)
        #expect(TestImages.pixel(of: result.image, x: 100, y: 60) == white)
        #expect(TestImages.pixel(of: result.image, x: 100, y: 20) == .blue)
        #expect(TestImages.pixel(of: result.image, x: 100, y: 100) == .blue)
    }

    @Test func flattenAppliesTheCrop() throws {
        // Red patch at pixels x 20..<60, y 10..<30, which is points
        // x 10..<30, y 5..<15.
        let image = TestImages.make(
            width: 200,
            height: 120,
            patchRect: CGRect(x: 20, y: 10, width: 40, height: 20)
        )
        let screenshot = Screenshot(image: image, scale: 2, capturedAt: Date())
        var document = AnnotationDocument()
        document.cropRect = CGRect(x: 10, y: 5, width: 20, height: 10)

        let result = try AnnotationRenderer.flatten(screenshot, with: document, blurredImage: nil)

        #expect(result.image.width == 40)
        #expect(result.image.height == 20)
        #expect(TestImages.pixel(of: result.image, x: 0, y: 0) == .red)
        #expect(TestImages.pixel(of: result.image, x: 39, y: 19) == .red)
    }

    @Test func flattenCopiesThePixelsOfACropThatFallsBetweenThem() throws {
        let image = TestImages.make(
            width: 200,
            height: 120,
            patchRect: CGRect(x: 20, y: 10, width: 40, height: 20)
        )
        let screenshot = Screenshot(image: image, scale: 2, capturedAt: Date())
        var document = AnnotationDocument()
        // A fifth of a pixel past the patch's top-left corner.
        document.cropRect = CGRect(x: 10.1, y: 5.1, width: 20, height: 10)

        let result = try AnnotationRenderer.flatten(screenshot, with: document, blurredImage: nil)

        #expect(result.image.width == 40)
        #expect(result.image.height == 20)
        // Pure red right up to the edges. Resampling would have blended in
        // the blue around the patch.
        #expect(TestImages.pixel(of: result.image, x: 0, y: 0) == .red)
        #expect(TestImages.pixel(of: result.image, x: 39, y: 19) == .red)
    }

    @Test func flattenFailsRatherThanLeaveABlurOut() {
        let screenshot = Screenshot(
            image: TestImages.make(width: 200, height: 120),
            scale: 2,
            capturedAt: Date()
        )
        var document = AnnotationDocument()
        document.annotations.append(
            Annotation(shape: .blur(CGRect(x: 10, y: 10, width: 40, height: 20)), color: .red, size: .medium)
        )

        // No blurred copy of the screenshot to draw the blur with: exporting
        // without it would show what the blur was meant to hide.
        #expect(throws: CaptureError.self) {
            try AnnotationRenderer.flatten(screenshot, with: document, blurredImage: nil)
        }
    }

    @Test func blurChangesOnlyTheInsideOfItsRectangle() throws {
        // A sharp red patch on blue. Blurring a region across its edge must
        // mix the two colours there, and leave everything else alone.
        let image = TestImages.make(
            width: 200,
            height: 120,
            patchRect: CGRect(x: 0, y: 0, width: 100, height: 120)
        )
        let screenshot = Screenshot(image: image, scale: 1, capturedAt: Date())
        let blurred = try #require(AnnotationRenderer.blurredImage(of: screenshot))
        var document = AnnotationDocument()
        document.annotations.append(
            Annotation(
                shape: .blur(CGRect(x: 80, y: 40, width: 40, height: 40)),
                color: .red,
                size: .medium
            )
        )

        let result = try AnnotationRenderer.flatten(screenshot, with: document, blurredImage: blurred)

        #expect(blurred.width == 200)
        #expect(blurred.height == 120)
        let mixed = TestImages.pixel(of: result.image, x: 100, y: 60)
        #expect(mixed.red > 40 && mixed.red < 215)
        #expect(mixed.blue > 40 && mixed.blue < 215)
        // Outside the rectangle the edge is still sharp.
        #expect(TestImages.pixel(of: result.image, x: 98, y: 10) == .red)
        #expect(TestImages.pixel(of: result.image, x: 102, y: 10) == .blue)
    }
}
