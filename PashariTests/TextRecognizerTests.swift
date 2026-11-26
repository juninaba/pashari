import AppKit
import CoreText
import Testing

@testable import Pashari

@MainActor
struct TextRecognizerTests {
    @Test(arguments: [
        ["Copy screen text"],
        ["画面の文字をコピー"],
        ["Helvetica 日本語"],
        ["Copy screen text", "画面の文字をコピー"],
    ])
    func recognizesEnglishAndJapaneseInLineOrder(_ lines: [String]) async throws {
        let text = try await TextRecognizer.recognize(makeImage(rows: lines.map { [$0] }))

        #expect(text == lines.joined(separator: "\n"))
    }

    @Test func joinsSeparatedFragmentsOnTheSameLine() async throws {
        let image = makeImage(rows: [["File name", "Quarterly Report.pdf"], ["Save settings"]])
        let text = try await TextRecognizer.recognize(image)

        #expect(text == "File name Quarterly Report.pdf\nSave settings")
    }

    @Test func returnsNilForAnImageWithoutText() async throws {
        let text = try await TextRecognizer.recognize(makeImage(rows: []))

        #expect(text == nil)
    }

    private func makeImage(rows: [[String]]) -> CGImage {
        let context = CGContext(
            data: nil, width: 1000, height: 220, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))

        let font = NSFont.systemFont(ofSize: 42)
        for (row, fragments) in rows.enumerated() {
            for (column, text) in fragments.enumerated() {
                let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
                context.textPosition = CGPoint(x: 30 + column * 460, y: 155 - row * 65)
                CTLineDraw(CTLineCreateWithAttributedString(string), context)
            }
        }
        return context.makeImage()!
    }
}
