import CoreGraphics
import Foundation

struct Screenshot {
    let image: CGImage

    /// Pixels per point. 2.0 on a Retina display, 1.0 on a standard one.
    let scale: CGFloat

    let capturedAt: Date

    var pointSize: CGSize {
        CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    /// `rect` is in points with the origin at the top-left corner, the same
    /// way the image is laid out. Returns nil when nothing is left after
    /// clipping `rect` to the image.
    func cropped(to rect: CGRect) -> Screenshot? {
        // Convert each edge to pixels separately, so that neighbouring
        // selections never overlap or leave a gap after rounding.
        let minX = max((rect.minX * scale).rounded(), 0)
        let minY = max((rect.minY * scale).rounded(), 0)
        let maxX = min((rect.maxX * scale).rounded(), CGFloat(image.width))
        let maxY = min((rect.maxY * scale).rounded(), CGFloat(image.height))
        guard maxX - minX >= 1, maxY - minY >= 1 else { return nil }

        let pixelRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard let croppedImage = image.cropping(to: pixelRect) else { return nil }
        return Screenshot(image: croppedImage, scale: scale, capturedAt: capturedAt)
    }
}
