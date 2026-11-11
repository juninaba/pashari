import AppKit
import SwiftUI
import Testing

@testable import Pashari

@MainActor
struct EditorKeyCommandTests {
    @Test func mapsTheEditorShortcuts() {
        #expect(EditorKeyCommand(key: "z", shift: false) == .undo)
        #expect(EditorKeyCommand(key: "z", shift: true) == .redo)
        #expect(EditorKeyCommand(key: "c", shift: false) == .copy)
        #expect(EditorKeyCommand(key: "s", shift: false) == .save)
        #expect(EditorKeyCommand(key: "w", shift: false) == .close)
    }

    @Test func otherKeysAreNotCommands() {
        #expect(EditorKeyCommand(key: "q", shift: false) == nil)
        #expect(EditorKeyCommand(key: "c", shift: true) == nil)
    }

    @Test func textEditingGetsTheStandardActions() {
        #expect(EditorWindow.textEditingAction(key: "v", shift: false) == #selector(NSText.paste(_:)))
        #expect(EditorWindow.textEditingAction(key: "a", shift: false) == #selector(NSText.selectAll(_:)))
        #expect(EditorWindow.textEditingAction(key: "s", shift: false) == nil)
    }
}

@MainActor
struct EditorToolTests {
    private let start = CGPoint(x: 50, y: 40)
    private let end = CGPoint(x: 10, y: 100)

    @Test func lineToolsKeepTheDragDirection() {
        #expect(EditorTool.arrow.shape(from: start, to: end) == .arrow(from: start, to: end))
        #expect(EditorTool.line.shape(from: start, to: end) == .line(from: start, to: end))
    }

    @Test func boxToolsNormaliseTheDragIntoARectangle() {
        let rect = CGRect(x: 10, y: 40, width: 40, height: 60)

        #expect(EditorTool.rectangle.shape(from: start, to: end) == .rectangle(rect))
        #expect(EditorTool.ellipse.shape(from: start, to: end) == .ellipse(rect))
        #expect(EditorTool.blur.shape(from: start, to: end) == .blur(rect))
    }

    @Test func otherToolsDoNotMakeAShapeFromADrag() {
        for tool in [EditorTool.select, .pen, .highlighter, .text, .counter, .crop] {
            #expect(tool.shape(from: start, to: end) == nil)
        }
    }

    @Test func everyToolHasAnExistingSymbolAndALabel() {
        for tool in EditorTool.allCases {
            #expect(NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: nil) != nil)
            #expect(!tool.label.isEmpty)
        }
    }
}

@MainActor
struct EditorModelTests {
    @Test func addedMarksUseTheSelectedColourAndSize() {
        let model = makeModel()
        model.color = .blue
        model.size = .large

        model.add(.rectangle(CGRect(x: 1, y: 2, width: 30, height: 40)))

        let annotation = model.document.annotations.last
        #expect(annotation?.color == .blue)
        #expect(annotation?.size == .large)
        #expect(annotation?.shape == .rectangle(CGRect(x: 1, y: 2, width: 30, height: 40)))
    }

    @Test func undoAndRedoStepThroughChanges() {
        let model = makeModel()
        #expect(!model.canUndo)

        model.add(.counter(1, center: CGPoint(x: 5, y: 5)))
        model.add(.counter(2, center: CGPoint(x: 9, y: 9)))
        model.undo()

        #expect(model.document.annotations.count == 1)
        #expect(model.canUndo)
        #expect(model.canRedo)

        model.redo()
        #expect(model.document.annotations.count == 2)
    }

    @Test func cropIsClippedToTheImageAndCanBeUndone() {
        let model = makeModel()  // 100 x 60 points

        model.crop(to: CGRect(x: 50, y: 20, width: 500, height: 500))

        #expect(model.visibleRect == CGRect(x: 50, y: 20, width: 50, height: 40))
        model.undo()
        #expect(model.visibleRect == CGRect(x: 0, y: 0, width: 100, height: 60))
    }

    @Test func cropEdgesLandOnWholePixels() {
        let model = makeModel()  // 2 pixels per point

        // A drag in a zoomed-out editor ends between pixels.
        model.crop(to: CGRect(x: 10.3, y: 5.2, width: 40.4, height: 20.1))

        #expect(model.visibleRect == CGRect(x: 10.5, y: 5, width: 40, height: 20.5))
    }

    @Test func aSecondCropStaysInsideTheFirst() {
        let model = makeModel()
        model.crop(to: CGRect(x: 20, y: 10, width: 60, height: 40))

        model.crop(to: CGRect(x: 0, y: 0, width: 50, height: 30))

        #expect(model.visibleRect == CGRect(x: 20, y: 10, width: 30, height: 20))
    }

    @Test func changesAreAnnounced() {
        let model = makeModel()
        var documentChanges = 0
        var toolChanges = 0
        model.onDocumentChange = { documentChanges += 1 }
        model.onToolChange = { toolChanges += 1 }

        model.add(.counter(1, center: .zero))
        model.undo()
        model.tool = .pen

        #expect(documentChanges == 2)
        #expect(toolChanges == 1)
    }

    @Test func flattenedIsTheOriginalWhenNothingChanged() {
        let model = makeModel()

        #expect(model.flattened().image === model.screenshot.image)
    }

    @Test func flattenedHasTheCroppedSize() {
        let model = makeModel()
        model.crop(to: CGRect(x: 10, y: 10, width: 40, height: 20))

        let result = model.flattened()

        #expect(result.image.width == 80)
        #expect(result.image.height == 40)
    }
}

/// Drives the canvas with hand-made mouse events, as the selection view
/// tests do.
@MainActor
struct AnnotationCanvasViewTests {
    @Test func draggingWithTheArrowToolAddsAnArrow() {
        let harness = CanvasHarness()
        harness.model.tool = .arrow

        harness.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 40))

        #expect(harness.shapes == [.arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 40))])
    }

    @Test func aBarelyMovedDragAddsNothing() {
        let harness = CanvasHarness()
        harness.model.tool = .rectangle

        harness.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 11, y: 11))

        #expect(harness.shapes.isEmpty)
        #expect(!harness.model.canUndo)
    }

    @Test func thePenCollectsEveryPointOfTheStroke() {
        let harness = CanvasHarness()
        harness.model.tool = .pen
        let points = [CGPoint(x: 5, y: 5), CGPoint(x: 10, y: 8), CGPoint(x: 20, y: 6)]

        harness.stroke(through: points)

        #expect(harness.shapes == [.pen(points)])
    }

    @Test func clickingWithTheNumberToolCountsUp() {
        let harness = CanvasHarness()
        harness.model.tool = .counter

        harness.click(at: CGPoint(x: 10, y: 10))
        harness.click(at: CGPoint(x: 30, y: 10))

        #expect(harness.shapes == [
            .counter(1, center: CGPoint(x: 10, y: 10)),
            .counter(2, center: CGPoint(x: 30, y: 10)),
        ])
    }

    @Test func croppingShrinksTheCanvasAndShiftsLaterMarks() {
        let harness = CanvasHarness()  // 100 x 60 points
        harness.model.tool = .crop
        harness.drag(from: CGPoint(x: 20, y: 10), to: CGPoint(x: 80, y: 50))

        #expect(harness.model.visibleRect == CGRect(x: 20, y: 10, width: 60, height: 40))
        #expect(harness.canvas.frame.size == CGSize(width: 60, height: 40))

        // The canvas now starts at the crop's corner, so a drag from the
        // view's (5, 5) is a drag from the image's (25, 15).
        harness.model.tool = .line
        harness.drag(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 35, y: 25))

        #expect(harness.shapes == [.line(from: CGPoint(x: 25, y: 15), to: CGPoint(x: 55, y: 35))])
    }

    @Test func undoingACropRestoresTheCanvasSize() {
        let harness = CanvasHarness()
        harness.model.tool = .crop
        harness.drag(from: CGPoint(x: 20, y: 10), to: CGPoint(x: 80, y: 50))

        harness.model.undo()

        #expect(harness.canvas.frame.size == CGSize(width: 100, height: 60))
    }

    @Test func dragsAreKeptInsideTheImage() {
        let harness = CanvasHarness()
        harness.model.tool = .rectangle

        harness.drag(from: CGPoint(x: 50, y: 30), to: CGPoint(x: 500, y: 500))

        #expect(harness.shapes == [.rectangle(CGRect(x: 50, y: 30, width: 50, height: 30))])
    }
}

@MainActor
struct EditorWindowTests {
    @Test func smallImagesGetTheMinimumWindowSize() {
        let size = AnnotationEditorWindowController.initialContentSize(
            for: CGSize(width: 200, height: 100),
            screenSize: CGSize(width: 1728, height: 1000)
        )

        #expect(size == CGSize(width: 900, height: 280 + EditorToolbarView.height))
    }

    @Test func largeImagesAreLimitedToMostOfTheScreen() {
        let size = AnnotationEditorWindowController.initialContentSize(
            for: CGSize(width: 3000, height: 2000),
            screenSize: CGSize(width: 2000, height: 1000)
        )

        #expect(size == CGSize(width: 1700, height: 850))
    }

    @Test func theWindowIsNeverNarrowerThanItsToolbar() throws {
        // A tiny image would otherwise get the smallest possible window.
        let screenshot = Screenshot(
            image: TestImages.make(width: 40, height: 40),
            scale: 2,
            capturedAt: Date()
        )
        let editor = AnnotationEditorWindowController(screenshot: screenshot)
        editor.onClose = nil

        editor.window.layoutIfNeeded()

        // The toolbar is the one SwiftUI-hosting view in the window. It must
        // have been given at least the width it asks for, both now and at
        // the smallest size the window can be resized to.
        let toolbar = try #require(
            editor.window.contentView?.subviews.first { $0 is NSHostingView<EditorToolbarView> }
        )
        #expect(toolbar.frame.width >= toolbar.fittingSize.width - 0.5)
        #expect(editor.window.contentMinSize.width >= toolbar.fittingSize.width - 0.5)
    }

    @Test func closingWithoutCopyOrSaveHandsTheResultBack() {
        let screenshot = makeScreenshot()
        let editor = AnnotationEditorWindowController(screenshot: screenshot)
        var results: [Screenshot?] = []
        editor.onClose = { results.append($0) }
        editor.model.add(.rectangle(CGRect(x: 5, y: 5, width: 30, height: 30)))

        editor.window.close()

        #expect(results.count == 1)
        let result = results.first ?? nil
        #expect(result != nil)
        // Annotated, so it is a new image rather than the original.
        #expect(result?.image !== screenshot.image)
    }
}

// MARK: - Helpers

@MainActor
func makeScreenshot() -> Screenshot {
    // 200 x 120 pixels at 2x: 100 x 60 points.
    Screenshot(image: TestImages.make(width: 200, height: 120), scale: 2, capturedAt: Date())
}

@MainActor
func makeModel() -> EditorModel {
    EditorModel(screenshot: makeScreenshot())
}

@MainActor
final class CanvasHarness {
    let model = makeModel()
    let canvas: AnnotationCanvasView
    let window: NSWindow

    init() {
        canvas = AnnotationCanvasView(model: model)
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        // A flipped container, so the canvas keeps its top-left origin when
        // it changes size.
        let container = FlippedView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        container.addSubview(canvas)
        window.contentView = container
    }

    var shapes: [Annotation.Shape] {
        model.document.annotations.map(\.shape)
    }

    /// Points are in the canvas's own coordinates.
    func drag(from: CGPoint, to: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        stroke(through: [from, to], modifiers: modifiers)
    }

    func stroke(through points: [CGPoint], modifiers: NSEvent.ModifierFlags = []) {
        canvas.mouseDown(with: event(.leftMouseDown, at: points[0], modifiers: modifiers))
        for point in points.dropFirst() {
            canvas.mouseDragged(with: event(.leftMouseDragged, at: point, modifiers: modifiers))
        }
        canvas.mouseUp(with: event(.leftMouseUp, at: points[points.count - 1], modifiers: modifiers))
    }

    func click(at point: CGPoint) {
        canvas.mouseDown(with: event(.leftMouseDown, at: point))
        canvas.mouseUp(with: event(.leftMouseUp, at: point))
    }

    func press(keyCode: Int) {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: UInt16(keyCode)
        )!
        canvas.keyDown(with: event)
    }

    private func event(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: canvas.convert(point, to: nil),
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
