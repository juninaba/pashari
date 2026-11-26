import AppKit
import CoreText
import Testing

@testable import Pashari

@MainActor
struct TextRecognizerTests {
    @Test func recognizesEnglishAndJapaneseInLineOrder() async throws {
        let lines = ["Copy screen text", "画面の文字をコピー"]
        let text = try await TextRecognizer.recognize(makeImage(lines: lines))

        #expect(text == lines.joined(separator: "\n"))
    }

    @Test func returnsNilForAnImageWithoutText() async throws {
        let text = try await TextRecognizer.recognize(makeImage(lines: []))

        #expect(text == nil)
    }

    private func makeImage(lines: [String]) -> CGImage {
        let context = CGContext(
            data: nil, width: 800, height: 220, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 220))

        let font = NSFont.systemFont(ofSize: 42)
        for (index, text) in lines.enumerated() {
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
            context.textPosition = CGPoint(x: 30, y: 155 - index * 65)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        return context.makeImage()!
    }
}
