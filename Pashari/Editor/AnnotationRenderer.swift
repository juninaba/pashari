import AppKit
import CoreImage

/// Draws a screenshot with its annotations.
///
/// The editor's canvas and the export both go through this one type, so what
/// is saved is exactly what was shown.
enum AnnotationRenderer {
    // MARK: - Drawing

    /// Draws the screenshot and then the annotations on top of it.
    ///
    /// The context must use image points with the origin at the top-left
    /// corner and y growing downwards.
    static func draw(
        _ annotations: [Annotation],
        over screenshot: Screenshot,
        blurredImage: CGImage?,
        in context: CGContext
    ) {
        let bounds = CGRect(origin: .zero, size: screenshot.pointSize)
        drawImage(screenshot.image, in: bounds, context: context)
        for annotation in annotations {
            draw(annotation, imageBounds: bounds, blurredImage: blurredImage, in: context)
        }
    }

    private static func draw(
        _ annotation: Annotation,
        imageBounds: CGRect,
        blurredImage: CGImage?,
        in context: CGContext
    ) {
        // Settings such as colour and line width stick to a context. Saving
        // and restoring keeps one annotation's settings from leaking into
        // the next.
        context.saveGState()
        defer { context.restoreGState() }

        let color = annotation.color.cgColor
        let lineWidth = annotation.size.lineWidth
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.shape {
        case .arrow(let from, let to):
            let head = arrowHead(from: from, to: to, lineWidth: lineWidth)
            // The shaft stops at the base of the head, so its round end does
            // not stick out past the tip.
            context.move(to: from)
            context.addLine(to: head.base)
            context.strokePath()
            context.move(to: to)
            context.addLine(to: head.left)
            context.addLine(to: head.right)
            context.closePath()
            context.fillPath()

        case .line(let from, let to):
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()

        case .rectangle(let rect):
            context.stroke(rect)

        case .ellipse(let rect):
            context.strokeEllipse(in: rect)

        case .pen(let points):
            context.addPath(smoothPath(through: points))
            context.strokePath()

        case .highlighter(let points):
            // "Multiply" darkens what is underneath instead of covering it,
            // the way a real highlighter leaves the text readable.
            context.setBlendMode(.multiply)
            context.setAlpha(0.45)
            context.setLineWidth(annotation.size.highlighterWidth)
            context.setLineCap(.butt)
            context.addPath(smoothPath(through: points))
            context.strokePath()

        case .text(let string, let origin):
            drawText(
                string,
                at: origin,
                attributes: textAttributes(color: annotation.color, size: annotation.size),
                in: context
            )

        case .blur(let rect):
            guard let blurredImage else { return }
            // The whole image exists in a blurred version; show it only
            // inside the rectangle.
            context.clip(to: rect)
            drawImage(blurredImage, in: imageBounds, context: context)

        case .counter(let number, let center):
            let radius = annotation.size.counterRadius
            context.fillEllipse(
                in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            )
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: radius * 1.15, weight: .bold),
                .foregroundColor: annotation.color.prefersDarkText ? NSColor.black : NSColor.white,
            ]
            let textSize = ("\(number)" as NSString).size(withAttributes: attributes)
            drawText(
                "\(number)",
                at: CGPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2),
                attributes: attributes,
                in: context
            )
        }
    }

    /// The font and colour of the text tool. The editor uses the same ones
    /// for the field the user types into, so nothing shifts on commit.
    static func textAttributes(
        color: AnnotationColor,
        size: StrokeSize
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: size.fontSize, weight: .semibold),
            .foregroundColor: NSColor(cgColor: color.cgColor) ?? .red,
        ]
    }

    /// The space the text tool's text takes up, line breaks included.
    static func textSize(of string: String, size: StrokeSize) -> CGSize {
        (string as NSString).size(withAttributes: textAttributes(color: .black, size: size))
    }

    // MARK: - Geometry

    struct ArrowHead: Equatable {
        /// Where the shaft meets the head, on the centre line.
        var base: CGPoint
        var left: CGPoint
        var right: CGPoint
    }

    /// The triangle at the `to` end of an arrow. It grows with the line
    /// width, and shrinks for arrows shorter than the head itself.
    static func arrowHead(from: CGPoint, to: CGPoint, lineWidth: CGFloat) -> ArrowHead {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > 0 else { return ArrowHead(base: to, left: to, right: to) }

        let headLength = min(max(lineWidth * 4.5, 12), length)
        let halfWidth = headLength * 0.45
        // Unit vector along the arrow, and the one at a right angle to it.
        let ux = dx / length
        let uy = dy / length
        let base = CGPoint(x: to.x - ux * headLength, y: to.y - uy * headLength)
        return ArrowHead(
            base: base,
            left: CGPoint(x: base.x - uy * halfWidth, y: base.y + ux * halfWidth),
            right: CGPoint(x: base.x + uy * halfWidth, y: base.y - ux * halfWidth)
        )
    }

    /// A curve through the points, for the pen and the highlighter. Joining
    /// the raw points with straight lines looks jagged; instead each point
    /// becomes the control point of a curve between the midpoints on either
    /// side of it. The select tool tests clicks against this same curve.
    static func smoothPath(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if let last = points.last { path.addLine(to: last) }
            return path
        }
        for index in 1..<(points.count - 1) {
            let current = points[index]
            let next = points[index + 1]
            let midpoint = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
            path.addQuadCurve(to: midpoint, control: current)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    // MARK: - Drawing helpers

    /// Draws an image the right way up. Core Graphics draws images with
    /// y growing upwards, so in a y-down context they come out upside down
    /// unless the axis is flipped back for the duration of the call.
    private static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    /// Draws text with AppKit, which is far simpler than raw Core Graphics.
    /// AppKit draws into "the current context", so make ours current first.
    private static func drawText(
        _ string: String,
        at origin: CGPoint,
        attributes: [NSAttributedString.Key: Any],
        in context: CGContext
    ) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        (string as NSString).draw(at: origin, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Blur

    /// A blurred copy of the whole screenshot, for the blur tool to show
    /// through its rectangles. Made once per screenshot.
    static func blurredImage(of screenshot: Screenshot) -> CGImage? {
        let input = CIImage(cgImage: screenshot.image)
        // The radius is in pixels; scale it so the result looks the same on
        // Retina and non-Retina screenshots.
        let sigma = Double(10 * screenshot.scale)
        let output = input
            // Repeat the edge pixels outwards, so the blur does not fade to
            // transparent at the borders.
            .clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: input.extent)
        return CIContext().createCGImage(output, from: input.extent)
    }

    // MARK: - Export

    /// Bakes the document into a new screenshot at full resolution: the
    /// annotations become pixels and the crop is applied.
    static func flatten(
        _ screenshot: Screenshot,
        with document: AnnotationDocument,
        blurredImage: CGImage?
    ) -> Screenshot? {
        let scale = screenshot.scale
        let imageBounds = CGRect(origin: .zero, size: screenshot.pointSize)
        let crop = (document.cropRect ?? imageBounds).intersection(imageBounds)
        // The crop in whole pixels. With the edges on whole pixels, the
        // screenshot is copied pixel for pixel instead of being resampled.
        // (The editor already crops on whole pixels; this also clears away
        // tiny floating-point errors.)
        let left = (crop.minX * scale).rounded()
        let top = (crop.minY * scale).rounded()
        let pixelWidth = Int((crop.maxX * scale).rounded() - left)
        let pixelHeight = Int((crop.maxY * scale).rounded() - top)
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        // Keep the screenshot's own colour space when it is an RGB one.
        var colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        if let original = screenshot.image.colorSpace, original.model == .rgb {
            colorSpace = original
        }
        guard
            let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        // A bitmap context starts out in pixels with y growing upwards.
        // Turn it into image points with y growing downwards, shifted so the
        // crop's top-left corner lands at the bitmap's top-left corner. Core
        // Graphics applies these steps to what is drawn in reverse order, so
        // read them from the bottom up: points become pixels, the crop's
        // corner moves to the origin, and y is flipped.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: 1, y: -1)
        // The shift is in whole pixels.
        context.translateBy(x: -left, y: -top)
        context.scaleBy(x: scale, y: scale)

        draw(document.annotations, over: screenshot, blurredImage: blurredImage, in: context)

        guard let image = context.makeImage() else { return nil }
        return Screenshot(image: image, scale: scale, capturedAt: screenshot.capturedAt)
    }
}
