import AppKit
import Testing

@testable import Pashari

@MainActor
struct TextToolTests {
    @Test func typedTextBecomesAnAnnotationAtTheClickedPoint() {
        let harness = CanvasHarness()
        harness.model.tool = .text

        harness.click(at: CGPoint(x: 20, y: 15))
        harness.type("Hello")
        harness.canvas.finishEditing()

        #expect(harness.shapes == [.text("Hello", origin: CGPoint(x: 20, y: 15))])
    }

    @Test func returnStartsANewLine() {
        let harness = CanvasHarness()
        harness.model.tool = .text
        harness.click(at: CGPoint(x: 20, y: 15))

        harness.type("first")
        harness.textView?.insertNewline(nil)
        // Right after Return the cursor is on a new, empty line. The view
        // must be two lines tall already, and no wider than the text.
        let afterReturn = harness.textView?.frame.size ?? .zero
        harness.type("second")

        #expect(afterReturn.width < 200)
        #expect(afterReturn.height > 30)
        #expect(harness.textView != nil)
        harness.canvas.finishEditing()
        #expect(harness.shapes == [.text("first\nsecond", origin: CGPoint(x: 20, y: 15))])
    }

    @Test func theTextViewGrowsWithItsText() throws {
        let harness = CanvasHarness()
        harness.model.tool = .text
        harness.click(at: CGPoint(x: 20, y: 15))
        let textView = try #require(harness.textView)
        let emptySize = textView.frame.size

        harness.type("a fairly long line of text")
        let oneLineSize = textView.frame.size
        textView.insertNewline(nil)
        harness.type("second")
        let twoLineSize = textView.frame.size

        #expect(oneLineSize.width > emptySize.width + 50)
        #expect(twoLineSize.height > oneLineSize.height * 1.8)
        #expect(twoLineSize.width < 400)
        #expect(twoLineSize.height < oneLineSize.height * 2.5)
        #expect(textView.frame.origin == CGPoint(x: 20, y: 15))
    }

    @Test func escapeFinishesTyping() throws {
        let harness = CanvasHarness()
        harness.model.tool = .text
        harness.click(at: CGPoint(x: 20, y: 15))
        harness.type("done")
        let textView = try #require(harness.textView)

        let handled = harness.canvas.textView(
            textView,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )

        #expect(handled)
        #expect(harness.textView == nil)
        #expect(harness.shapes == [.text("done", origin: CGPoint(x: 20, y: 15))])
    }

    @Test func otherKeyCommandsAreLeftToTheTextView() throws {
        let harness = CanvasHarness()
        harness.model.tool = .text
        harness.click(at: CGPoint(x: 20, y: 15))
        let textView = try #require(harness.textView)

        let handled = harness.canvas.textView(
            textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )

        #expect(!handled)
    }

    @Test func emptyTextAddsNothing() {
        let harness = CanvasHarness()
        harness.model.tool = .text
        harness.click(at: CGPoint(x: 20, y: 15))

        harness.type("  ")
        harness.textView?.insertNewline(nil)
        harness.canvas.finishEditing()

        #expect(harness.shapes.isEmpty)
        #expect(!harness.model.canUndo)
    }

    @Test func blankLinesAtTheEndsAreDropped() {
        let harness = CanvasHarness()
        harness.model.tool = .text
        harness.click(at: CGPoint(x: 20, y: 15))

        harness.textView?.insertNewline(nil)
        harness.type("one")
        harness.textView?.insertNewline(nil)
        harness.textView?.insertNewline(nil)
        harness.type("two")
        harness.textView?.insertNewline(nil)
        harness.canvas.finishEditing()

        #expect(harness.shapes == [.text("one\n\ntwo", origin: CGPoint(x: 20, y: 15))])
    }

    @Test func switchingToolsFinishesTyping() {
        let harness = CanvasHarness()
        harness.model.tool = .text
        harness.click(at: CGPoint(x: 20, y: 15))
        harness.type("kept")

        harness.model.tool = .arrow

        #expect(harness.textView == nil)
        #expect(harness.shapes == [.text("kept", origin: CGPoint(x: 20, y: 15))])
    }

    @Test func changingColourOrSizeWhileTypingRestylesTheText() throws {
        let harness = CanvasHarness()
        harness.model.tool = .text
        harness.click(at: CGPoint(x: 20, y: 15))
        harness.type("note")
        let textView = try #require(harness.textView)
        let sizeBefore = textView.frame.size

        harness.model.color = .blue
        harness.model.size = .large

        let large = AnnotationRenderer.textAttributes(color: .blue, size: .large)
        #expect(textView.font == large[.font] as? NSFont)
        #expect(textView.textColor == large[.foregroundColor] as? NSColor)
        #expect(textView.frame.width > sizeBefore.width)
        #expect(textView.frame.height > sizeBefore.height)
        harness.canvas.finishEditing()
        let annotation = harness.model.document.annotations.last
        #expect(annotation?.color == .blue)
        #expect(annotation?.size == .large)
    }

    @Test func textUsesTheSelectedColourAndSize() {
        let harness = CanvasHarness()
        harness.model.tool = .text
        harness.model.color = .blue
        harness.model.size = .large

        harness.click(at: CGPoint(x: 20, y: 15))
        harness.type("styled")
        harness.canvas.finishEditing()

        let annotation = harness.model.document.annotations.last
        #expect(annotation?.color == .blue)
        #expect(annotation?.size == .large)
    }

    @Test func doubleClickingExistingTextReEditsItInOneUndoStep() throws {
        let harness = CanvasHarness()
        harness.model.color = .green
        harness.model.size = .small
        harness.model.add(.text("Hello", origin: CGPoint(x: 20, y: 15)))
        let original = try #require(harness.model.document.annotations.first)
        harness.model.color = .red
        harness.model.size = .large

        harness.model.tool = .select
        harness.doubleClick(at: CGPoint(x: original.bounds.maxX - 1, y: original.bounds.midY))

        let textView = try #require(harness.textView)
        #expect(harness.model.editingTextID == original.id)
        #expect(textView.string == "Hello")
        #expect(textView.frame.origin == CGPoint(x: 20, y: 15))
        #expect(harness.model.displayedColor == .green)
        #expect(harness.model.displayedSize == .small)

        harness.type(" world")
        harness.canvas.finishEditing()

        #expect(harness.textView == nil)
        #expect(harness.model.editingTextID == nil)
        let updated = try #require(harness.model.document.annotations.first)
        #expect(updated.id == original.id)
        #expect(updated.shape == .text("Hello world", origin: CGPoint(x: 20, y: 15)))
        #expect(updated.color == .green)
        #expect(updated.size == .small)
        // Default drawing style stays untouched when style was not changed.
        #expect(harness.model.color == .red)
        #expect(harness.model.size == .large)

        // One undo step restores the original text.
        harness.model.undo()
        #expect(harness.shapes == [.text("Hello", origin: CGPoint(x: 20, y: 15))])
    }

    @Test func changingStyleWhileReEditingTextAppliesLiveAndCommitsInOneUndoStep() throws {
        let harness = CanvasHarness()
        harness.model.color = .red
        harness.model.size = .small
        harness.model.add(.text("Note", origin: CGPoint(x: 15, y: 15)))
        let original = try #require(harness.model.document.annotations.first)
        harness.model.tool = .select

        harness.doubleClick(at: CGPoint(x: original.bounds.maxX - 1, y: original.bounds.midY))
        let textView = try #require(harness.textView)

        harness.type("!")
        harness.model.chooseColor(.blue)
        harness.model.chooseSize(.large)

        let expected = AnnotationRenderer.textAttributes(color: .blue, size: .large)
        #expect(textView.font == expected[.font] as? NSFont)
        #expect(textView.textColor == expected[.foregroundColor] as? NSColor)
        #expect(harness.model.displayedColor == .blue)
        #expect(harness.model.displayedSize == .large)

        harness.canvas.finishEditing()

        let updated = try #require(harness.model.document.annotations.first)
        #expect(updated.shape == .text("Note!", origin: CGPoint(x: 15, y: 15)))
        #expect(updated.color == .blue)
        #expect(updated.size == .large)

        // Text, colour and size all revert together in a single undo step.
        harness.model.undo()
        let reverted = try #require(harness.model.document.annotations.first)
        #expect(reverted.shape == .text("Note", origin: CGPoint(x: 15, y: 15)))
        #expect(reverted.color == .red)
        #expect(reverted.size == .small)
    }

    @Test func clearingTextDuringReEditDeletesTheAnnotationInOneUndoStep() throws {
        let harness = CanvasHarness()
        harness.model.add(.text("Remove me", origin: CGPoint(x: 15, y: 15)))
        harness.model.tool = .select

        harness.doubleClick(at: CGPoint(x: 20, y: 20))
        let textView = try #require(harness.textView)
        textView.string = "   \n  "
        harness.canvas.finishEditing()

        #expect(harness.shapes.isEmpty)
        #expect(harness.model.selectedID == nil)

        harness.model.undo()
        #expect(harness.shapes == [.text("Remove me", origin: CGPoint(x: 15, y: 15))])
    }

    @Test func reEditingTextWithoutChangesAddsNoUndoStep() {
        let harness = CanvasHarness()
        harness.model.add(.text("Same", origin: CGPoint(x: 15, y: 15)))
        harness.model.tool = .select

        harness.doubleClick(at: CGPoint(x: 20, y: 20))
        harness.canvas.finishEditing()

        // Only the initial add is on the undo stack.
        harness.model.undo()
        #expect(harness.shapes.isEmpty)
    }

    @Test func switchingToolsWhileReEditingCommitsTheTextEdit() throws {
        let harness = CanvasHarness()
        harness.model.color = .green
        harness.model.size = .small
        harness.model.add(.text("Old", origin: CGPoint(x: 15, y: 15)))
        harness.model.color = .blue
        harness.model.size = .large
        harness.model.tool = .select

        harness.doubleClick(at: CGPoint(x: 20, y: 20))
        let textView = try #require(harness.textView)
        textView.string = "New"

        harness.model.tool = .arrow

        #expect(harness.textView == nil)
        #expect(harness.model.editingTextID == nil)
        #expect(harness.model.selectedID == nil)
        let updated = try #require(harness.model.document.annotations.first)
        #expect(updated.shape == .text("New", origin: CGPoint(x: 15, y: 15)))
        #expect(updated.color == .green)
        #expect(updated.size == .small)
        #expect(harness.model.displayedColor == .blue)
        #expect(harness.model.displayedSize == .large)
    }

    @Test func reEditingTextDoesNotDoubleDrawTheOriginalUnderneath() throws {
        // Blue background, white text. While editing, the canvas itself must
        // skip drawing the original white text (the NSTextView draws it instead).
        let harness = CanvasHarness()
        harness.model.color = .white
        harness.model.size = .large
        harness.model.add(.text("MMM", origin: CGPoint(x: 10, y: 10)))
        harness.model.tool = .select

        func canvasHasNonBluePixels() throws -> Bool {
            let bounds = harness.canvas.bounds
            let width = Int(bounds.width)
            let height = Int(bounds.height)
            let context = try #require(
                CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            )
            // Match a flipped NSView context (origin at top-left, y growing down).
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            harness.canvas.draw(bounds)
            NSGraphicsContext.restoreGraphicsState()
            let image = try #require(context.makeImage())
            for y in stride(from: 0, to: image.height, by: 2) {
                for x in stride(from: 0, to: image.width, by: 2) {
                    if TestImages.pixel(of: image, x: x, y: y) != .blue {
                        return true
                    }
                }
            }
            return false
        }

        #expect(try canvasHasNonBluePixels())

        harness.doubleClick(at: CGPoint(x: 20, y: 20))
        #expect(harness.model.editingTextID != nil)
        #expect(try !canvasHasNonBluePixels())

        harness.canvas.finishEditing()
        #expect(try canvasHasNonBluePixels())
    }

    @Test func typingUndoWhileReEditingKeepsTheChangedStyle() throws {
        let harness = CanvasHarness()
        harness.model.color = .red
        harness.model.size = .small
        harness.model.add(.text("Hello", origin: CGPoint(x: 15, y: 15)))
        harness.model.tool = .select

        harness.doubleClick(at: CGPoint(x: 20, y: 20))
        let textView = try #require(harness.textView)
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        harness.type("World")

        harness.model.chooseColor(.blue)
        harness.model.chooseSize(.large)

        harness.canvas.undo(nil)

        #expect(textView.string == "Hello")
        let expected = AnnotationRenderer.textAttributes(color: .blue, size: .large)
        let storage = try #require(textView.textStorage)
        #expect(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == expected[.font] as? NSFont)
        #expect(
            storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                == expected[.foregroundColor] as? NSColor
        )

        harness.canvas.redo(nil)
        #expect(textView.string == "World")
        #expect(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == expected[.font] as? NSFont)
        #expect(
            storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                == expected[.foregroundColor] as? NSColor
        )
    }

    @Test func toolbarUndoRedoAvailabilityTracksTypingDuringTextEditing() throws {
        let harness = CanvasHarness()
        harness.model.add(.text("Hello", origin: CGPoint(x: 15, y: 15)))
        // Document has undo history, no redo history.
        #expect(harness.model.canUndo)
        #expect(!harness.model.canRedo)

        harness.model.tool = .select
        harness.doubleClick(at: CGPoint(x: 20, y: 20))
        // Immediately on opening inline edit, typing has nothing to undo or redo.
        #expect(!harness.model.canUndo)
        #expect(!harness.model.canRedo)

        harness.type("!")
        #expect(harness.model.canUndo)
        #expect(!harness.model.canRedo)

        harness.canvas.undo(nil)
        #expect(!harness.model.canUndo)
        #expect(harness.model.canRedo)

        harness.canvas.redo(nil)
        #expect(harness.model.canUndo)
        #expect(!harness.model.canRedo)

        // Finishing restores document history availability and leaves the shared
        // window undo manager clean for the next text session.
        harness.canvas.finishEditing()
        #expect(harness.model.canUndo)
        #expect(!harness.model.canRedo)

        harness.model.tool = .text
        harness.click(at: CGPoint(x: 15, y: 35))
        #expect(!harness.model.canUndo)
        #expect(!harness.model.canRedo)
    }

    @Test func doubleClickingCroppedTextPlacesCaretAtTheClickedVisibleCharacter() throws {
        let harness = CanvasHarness()
        harness.model.size = .medium
        harness.model.add(.text("Hello world from Pashari", origin: CGPoint(x: 10, y: 15)))
        // Crop right edge so the tail of the text is hidden past x = 55.
        harness.model.crop(to: CGRect(x: 0, y: 0, width: 55, height: 60))
        harness.model.tool = .select

        // Double-click near the start of the visible prefix ("Hello").
        harness.doubleClick(at: CGPoint(x: 25, y: 22))
        let textView = try #require(harness.textView)
        let caret = textView.selectedRange().location
        #expect(caret > 0 && caret < ("Hello world from Pashari" as NSString).length)
        #expect(caret <= 5)

        harness.type("X")
        harness.canvas.finishEditing()
        let updated = try #require(harness.model.document.annotations.first)
        if case .text(let string, _) = updated.shape {
            #expect(string.prefix(6).contains("X"))
        } else {
            Issue.record("Expected updated text shape")
        }
    }

    @Test func doubleClickingNearCropEdgeKeepsCaretInsideVisibleCrop() throws {
        func renderedCaretImageX(in harness: CanvasHarness) throws -> CGFloat {
            let textView = try #require(harness.textView)
            let caret = textView.selectedRange().location
            let screenRect = textView.firstRect(
                forCharacterRange: NSRange(location: caret, length: 0),
                actualRange: nil
            )
            try #require(screenRect != .zero)
            let windowRect = harness.window.convertFromScreen(screenRect)
            let canvasRect = harness.canvas.convert(windowRect, from: nil)
            return canvasRect.minX + harness.model.visibleRect.minX
        }

        // Left-to-right text with a glyph straddling the right crop edge at x = 33.
        let harness = CanvasHarness()
        harness.model.size = .medium
        harness.model.add(.text("Hello world", origin: CGPoint(x: 10, y: 15)))
        harness.model.crop(to: CGRect(x: 0, y: 0, width: 33, height: 60))
        harness.model.tool = .select

        harness.doubleClick(at: CGPoint(x: 32, y: 22))
        let ltrCaretX = try renderedCaretImageX(in: harness)
        #expect(ltrCaretX >= 0 && ltrCaretX <= 33)

        // Bidirectional text cropped to x = 30...40: clicking x = 34 keeps the caret inside the crop.
        let bidiHarness = CanvasHarness()
        bidiHarness.model.size = .medium
        bidiHarness.model.add(.text("a אבג z", origin: CGPoint(x: 10, y: 15)))
        bidiHarness.model.crop(to: CGRect(x: 30, y: 0, width: 10, height: 60))
        bidiHarness.model.tool = .select

        // Canvas coordinates are relative to visibleRect (minX = 30), so x = 4 is image x = 34.
        bidiHarness.doubleClick(at: CGPoint(x: 4, y: 22))
        let bidiCaretX = try renderedCaretImageX(in: bidiHarness)
        #expect(bidiCaretX >= 30 && bidiCaretX <= 40)

        // Devanagari conjunct cluster cropped to x = 20...45: clicking x = 38 keeps the caret
        // at a composed-character boundary inside the crop.
        let devanagariHarness = CanvasHarness()
        devanagariHarness.model.size = .medium
        devanagariHarness.model.add(.text("नमस्ते", origin: CGPoint(x: 10, y: 15)))
        devanagariHarness.model.crop(to: CGRect(x: 20, y: 0, width: 25, height: 60))
        devanagariHarness.model.tool = .select

        // Canvas coordinates are relative to visibleRect (minX = 20), so x = 18 is image x = 38.
        devanagariHarness.doubleClick(at: CGPoint(x: 18, y: 22))
        let devanagariView = try #require(devanagariHarness.textView)
        let devanagariCaret = devanagariView.selectedRange().location
        let devanagariString = devanagariView.string as NSString
        if devanagariCaret < devanagariString.length {
            #expect(devanagariString.rangeOfComposedCharacterSequence(at: devanagariCaret).location == devanagariCaret)
        }
        let devanagariCaretX = try renderedCaretImageX(in: devanagariHarness)
        #expect(devanagariCaretX >= 20 && devanagariCaretX <= 45)

        // Devanagari narrow crop with no grapheme boundary inside x = 35...52:
        // fallback still rounds to the cluster boundary instead of splitting the conjunct.
        let narrowDevanagari = CanvasHarness()
        narrowDevanagari.model.size = .medium
        narrowDevanagari.model.add(.text("नमस्ते", origin: CGPoint(x: 10, y: 15)))
        narrowDevanagari.model.crop(to: CGRect(x: 35, y: 0, width: 17, height: 60))
        narrowDevanagari.model.tool = .select

        narrowDevanagari.doubleClick(at: CGPoint(x: 5, y: 22))  // image x = 40
        narrowDevanagari.type("X")
        narrowDevanagari.canvas.finishEditing()
        #expect(narrowDevanagari.shapes == [.text("नमXस्ते", origin: CGPoint(x: 10, y: 15))])

        // Pure RTL text cropped to x = 9...21: double-clicking near its visible trailing end
        // (x = 12 -> canvas x = 3) keeps the caret at the end so typing appends.
        let rtlTrailing = CanvasHarness()
        rtlTrailing.model.size = .medium
        rtlTrailing.model.add(.text("אבג", origin: CGPoint(x: 10, y: 15)))
        rtlTrailing.model.crop(to: CGRect(x: 9, y: 0, width: 12, height: 60))
        rtlTrailing.model.tool = .select

        rtlTrailing.doubleClick(at: CGPoint(x: 3, y: 22))
        rtlTrailing.type("ד")
        rtlTrailing.canvas.finishEditing()
        #expect(rtlTrailing.shapes == [.text("אבגד", origin: CGPoint(x: 10, y: 15))])

        // Pure RTL text cropped to its visible leading end (x = 36...47):
        // clicking x = 36.5 (canvas x = 0.5) inserts at the visible start rather than the hidden end.
        let rtlLeading = CanvasHarness()
        rtlLeading.model.size = .medium
        rtlLeading.model.add(.text("אבג", origin: CGPoint(x: 10, y: 15)))
        rtlLeading.model.crop(to: CGRect(x: 36, y: 0, width: 11, height: 60))
        rtlLeading.model.tool = .select

        rtlLeading.doubleClick(at: CGPoint(x: 0.5, y: 22))
        rtlLeading.type("ד")
        rtlLeading.canvas.finishEditing()
        #expect(rtlLeading.shapes == [.text("דאבג", origin: CGPoint(x: 10, y: 15))])

        // Arabic ligature cropped to x = 15...26: clicking x = 25.5 (canvas x = 10.5)
        // keeps the visible rendered caret inside the ligature (`سلXام`).
        let arabicHarness = CanvasHarness()
        arabicHarness.model.size = .medium
        arabicHarness.model.add(.text("سلام", origin: CGPoint(x: 10, y: 15)))
        arabicHarness.model.crop(to: CGRect(x: 15, y: 0, width: 11, height: 60))
        arabicHarness.model.tool = .select

        arabicHarness.doubleClick(at: CGPoint(x: 10.5, y: 22))
        let arabicCaretX = try renderedCaretImageX(in: arabicHarness)
        #expect(arabicCaretX >= 15 && arabicCaretX <= 26)
        arabicHarness.type("X")
        arabicHarness.canvas.finishEditing()
        #expect(arabicHarness.shapes == [.text("سلXام", origin: CGPoint(x: 10, y: 15))])
    }
}

extension CanvasHarness {
    var textView: NSTextView? {
        canvas.subviews.compactMap { $0 as? NSTextView }.first
    }

    func type(_ text: String) {
        guard let textView else { return }
        textView.insertText(text, replacementRange: textView.selectedRange())
    }
}
