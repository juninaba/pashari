import AppKit

extension NSCursor {
    /// A camera, shown while the user picks a window to capture, so it is
    /// clear at a glance that Pashari is waiting for a click. macOS's own
    /// screenshot tool shows one in its window mode too.
    ///
    /// Falls back to the arrow if the camera symbol cannot be drawn.
    static let camera: NSCursor = makeCameraCursor() ?? .arrow

    /// Size of the cursor image, in points.
    static let cameraCursorSize = CGSize(width: 28, height: 28)

    private static func makeCameraCursor() -> NSCursor? {
        guard
            let black = cameraSymbol(color: .black),
            let white = cameraSymbol(color: .white)
        else { return nil }

        let image = NSImage(size: cameraCursorSize)
        // One bitmap per pixel density, so the camera is sharp on both
        // regular and Retina displays. NSCursor picks the one that fits.
        for scale in [1, 2] {
            guard let bitmap = cameraBitmap(scale: scale, black: black, white: white) else { return nil }
            image.addRepresentation(bitmap)
        }
        // A click counts at the hot spot. The camera has no tip to point
        // with, so it sits in the middle, where the eye looks.
        return NSCursor(
            image: image,
            hotSpot: NSPoint(x: cameraCursorSize.width / 2, y: cameraCursorSize.height / 2)
        )
    }

    /// Draws a black camera with a white outline, so it stands out on both
    /// dark and light screens.
    private static func cameraBitmap(scale: Int, black: NSImage, white: NSImage) -> NSBitmapImageRep? {
        let size = cameraCursorSize
        guard
            let context = CGContext(
                data: nil,
                width: Int(size.width) * scale,
                height: Int(size.height) * scale,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        // Draw in points; the context turns them into pixels.
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

        let symbolRect = CGRect(
            origin: centeredOrigin(of: black.size, in: size),
            size: black.size
        )
        // The outline: the white camera, nudged a little in every direction.
        let outlineWidth: CGFloat = 1.5
        for step in 0..<12 {
            let angle = CGFloat(step) * .pi / 6
            white.draw(in: symbolRect.offsetBy(dx: cos(angle) * outlineWidth, dy: sin(angle) * outlineWidth))
        }
        black.draw(in: symbolRect)

        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = context.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        // Without this the bitmap would count each pixel as one point, and
        // the 2x version would show at twice the size.
        bitmap.size = size
        return bitmap
    }

    /// Where `size` sits in the middle of `canvas`, on whole points. The
    /// camera is 23 points wide, so exact centering would put it half a
    /// point over, between two pixels on a regular display, and its edges
    /// would blur.
    static func centeredOrigin(of size: CGSize, in canvas: CGSize) -> CGPoint {
        CGPoint(
            x: ((canvas.width - size.width) / 2).rounded(.down),
            y: ((canvas.height - size.height) / 2).rounded(.down)
        )
    }

    private static func cameraSymbol(color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }
}
