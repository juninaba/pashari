import CoreGraphics
import Foundation
import Testing

@testable import Pashari

@MainActor
struct ScreenshotTests {
    @Test func pointSizeDividesPixelsByScale() {
        let screenshot = makeScreenshot(width: 200, height: 120, scale: 2)

        #expect(screenshot.pointSize == CGSize(width: 100, height: 60))
    }

    @Test func cropConvertsPointsToPixels() throws {
        let screenshot = makeScreenshot(width: 200, height: 120, scale: 2)

        let cropped = try #require(screenshot.cropped(to: CGRect(x: 10, y: 20, width: 50, height: 30)))

        #expect(cropped.image.width == 100)
        #expect(cropped.image.height == 60)
        #expect(cropped.scale == 2)
    }

    @Test func cropMeasuresFromTheTopLeftCorner() throws {
        let image = TestImages.make(
            width: 200,
            height: 120,
            patchRect: CGRect(x: 20, y: 10, width: 40, height: 20)
        )
        let screenshot = Screenshot(image: image, scale: 2, capturedAt: Date())

        // The same patch in points.
        let cropped = try #require(screenshot.cropped(to: CGRect(x: 10, y: 5, width: 20, height: 10)))

        #expect(cropped.image.width == 40)
        #expect(cropped.image.height == 20)
        #expect(TestImages.pixel(of: cropped.image, x: 0, y: 0) == .red)
        #expect(TestImages.pixel(of: cropped.image, x: 39, y: 19) == .red)
    }

    @Test func cropIsClippedToTheImage() throws {
        let screenshot = makeScreenshot(width: 200, height: 120, scale: 2)

        let cropped = try #require(
            screenshot.cropped(to: CGRect(x: 90, y: 50, width: 500, height: 500))
        )

        #expect(cropped.image.width == 20)
        #expect(cropped.image.height == 20)
    }

    @Test func cropOutsideTheImageIsNil() {
        let screenshot = makeScreenshot(width: 200, height: 120, scale: 2)

        #expect(screenshot.cropped(to: CGRect(x: 300, y: 300, width: 10, height: 10)) == nil)
        #expect(screenshot.cropped(to: CGRect(x: 10, y: 10, width: 0, height: 0)) == nil)
    }

    private func makeScreenshot(width: Int, height: Int, scale: CGFloat) -> Screenshot {
        Screenshot(
            image: TestImages.make(width: width, height: height),
            scale: scale,
            capturedAt: Date()
        )
    }
}
