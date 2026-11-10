import AppKit
import Testing

@testable import Pashari

/// The text tool: click to start typing, Return for a new line, Escape or a
/// click elsewhere to finish.
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
        // Still typing: Return did not finish the text.
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
        // It fits the text, rather than simply being enormous.
        #expect(twoLineSize.width < 400)
        #expect(twoLineSize.height < oneLineSize.height * 2.5)
        // The top-left corner stays where the user clicked.
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
}

extension CanvasHarness {
    /// The view the text tool is typing into, if any.
    var textView: NSTextView? {
        canvas.subviews.compactMap { $0 as? NSTextView }.first
    }

    /// Inserts text at the cursor, the way typing does.
    func type(_ text: String) {
        guard let textView else { return }
        textView.insertText(text, replacementRange: textView.selectedRange())
    }
}
