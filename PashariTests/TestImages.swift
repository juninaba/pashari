import CoreGraphics
import Foundation

/// Helpers for building and inspecting small images in tests.
enum TestImages {
    /// Signals when the image's source pixels are actually freed, on any thread.
    static func tracked(released: DispatchSemaphore) -> CGImage {
        let width = 60
        let height = 40
        let count = width * height * 4
        let pixels = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        pixels.initializeMemory(as: UInt8.self, repeating: 255, count: count)
        let provider = CGDataProvider(
            dataInfo: Unmanaged.passRetained(released).toOpaque(), data: pixels, size: count
        ) { info, data, _ in
            data.deallocate()
            Unmanaged<DispatchSemaphore>.fromOpaque(info!).takeRetainedValue().signal()
        }!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    struct RGBA: Equatable {
        var red: UInt8
        var green: UInt8
        var blue: UInt8
        var alpha: UInt8

        static let red = RGBA(red: 255, green: 0, blue: 0, alpha: 255)
        static let blue = RGBA(red: 0, green: 0, blue: 255, alpha: 255)
    }

    /// An image filled with `background`, with `patch` painted over
    /// `patchRect`. `patchRect` is in pixels, origin at the top-left corner.
    static func make(
        width: Int,
        height: Int,
        background: RGBA = .blue,
        patch: RGBA = .red,
        patchRect: CGRect = .zero
    ) -> CGImage {
        let context = makeContext(width: width, height: height)
        context.setFillColor(color(background))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Core Graphics contexts have their origin at the bottom-left.
        context.setFillColor(color(patch))
        context.fill(
            CGRect(
                x: patchRect.minX,
                y: CGFloat(height) - patchRect.maxY,
                width: patchRect.width,
                height: patchRect.height
            )
        )
        return context.makeImage()!
    }

    /// The colour of one pixel. `x` and `y` count from the top-left corner.
    static func pixel(of image: CGImage, x: Int, y: Int) -> RGBA {
        let context = makeContext(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // The bitmap's rows are stored top row first.
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = y * context.bytesPerRow + x * 4
        return RGBA(
            red: bytes[offset],
            green: bytes[offset + 1],
            blue: bytes[offset + 2],
            alpha: bytes[offset + 3]
        )
    }

    private static func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }

    private static func color(_ rgba: RGBA) -> CGColor {
        CGColor(
            srgbRed: CGFloat(rgba.red) / 255,
            green: CGFloat(rgba.green) / 255,
            blue: CGFloat(rgba.blue) / 255,
            alpha: CGFloat(rgba.alpha) / 255
        )
    }
}
