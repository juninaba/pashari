import CoreGraphics

/// Geometry in AppKit screen coordinates. The white border and the toolbar
/// keep their size as the picture zooms.
enum PinnedScreenshotLayout {
    static let border: CGFloat = 8
    static let toolbarHeight: CGFloat = 36
    static let minimumCardWidth: CGFloat = 150
    static let maximumToolbarWidth: CGFloat = 200
    private static let minimumPictureSide: CGFloat = 80
    private static let cascadeStep: CGFloat = 24

    struct Placement: Equatable {
        let frame: CGRect
        let imageSize: CGSize

        var imageBounds: CGRect {
            CGRect(
                x: (frame.width - imageSize.width) / 2,
                y: PinnedScreenshotLayout.toolbarHeight,
                width: imageSize.width,
                height: imageSize.height
            )
        }

        var imageFrame: CGRect {
            imageBounds.offsetBy(dx: frame.minX, dy: frame.minY)
        }
    }

    static func initialPlacement(
        imageSize: CGSize,
        captureFrame: CGRect?,
        visibleFrame: CGRect,
        occupiedFrames: [CGRect] = []
    ) -> Placement {
        let scale = min(1, fittingScale(for: imageSize, in: visibleFrame))
        let size = scaledSize(imageSize, by: scale)
        let cardSize = cardSize(for: size)
        let location: CGPoint
        if let captureFrame, scale == 1, visibleFrame.contains(captureFrame) {
            // Align the picture itself with the capture, then fit the paper
            // edge if the selection was close to the edge of the screen.
            location = CGPoint(
                x: captureFrame.minX - (cardSize.width - size.width) / 2,
                y: captureFrame.maxY - size.height - toolbarHeight
            )
        } else {
            location = CGPoint(
                x: visibleFrame.midX - cardSize.width / 2,
                y: visibleFrame.midY - cardSize.height / 2
            )
        }

        func hasPin(at origin: CGPoint) -> Bool {
            // AppKit can round the window's position when it is displayed.
            occupiedFrames.contains { abs($0.minX - origin.x) < 1 && abs($0.minY - origin.y) < 1 }
        }

        func unoccupiedFrame(startingAt frame: CGRect) -> CGRect? {
            guard hasPin(at: frame.origin) else { return frame }
            for step in 1...occupiedFrames.count {
                let offset = CGFloat(step) * cascadeStep
                for direction: CGFloat in [1, -1] {
                    let shifted = confined(
                        frame.offsetBy(dx: offset * direction, dy: -offset * direction), to: visibleFrame
                    )
                    if !hasPin(at: shifted.origin) { return shifted }
                }
            }
            return nil
        }

        let frame = confined(CGRect(origin: location, size: cardSize), to: visibleFrame)
        if let freeFrame = unoccupiedFrame(startingAt: frame) {
            return Placement(frame: freeFrame, imageSize: size)
        }

        // If there is no room to offset a screen-filling pin, leave a
        // margin around the new pin so the one under it is still reachable.
        let inset = visibleFrame.insetBy(dx: cascadeStep, dy: cascadeStep)
        let reducedSize = scaledSize(imageSize, by: min(scale, fittingScale(for: imageSize, in: inset)))
        let reducedCard = Self.cardSize(for: reducedSize)
        let reducedFrame = CGRect(
            x: frame.midX - reducedCard.width / 2, y: frame.midY - reducedCard.height / 2,
            width: reducedCard.width, height: reducedCard.height
        )
        return Placement(frame: unoccupiedFrame(startingAt: reducedFrame) ?? reducedFrame, imageSize: reducedSize)
    }

    /// Keep the point beneath the pointer in place while the image zooms.
    /// On the paper margin, zoom around the picture's centre.
    static func zoomed(
        _ placement: Placement,
        originalSize: CGSize,
        by factor: CGFloat,
        at anchor: CGPoint,
        in visibleFrame: CGRect
    ) -> Placement {
        let currentScale = placement.imageSize.width / originalSize.width
        let minimumScale = min(1, minimumPictureSide / max(originalSize.width, originalSize.height))
        let scale = min(max(currentScale * factor, minimumScale), fittingScale(for: originalSize, in: visibleFrame))
        guard scale != currentScale else { return placement }
        let size = scaledSize(originalSize, by: scale)
        let cardSize = cardSize(for: size)
        let picture = placement.imageFrame
        let anchor = picture.contains(anchor) ? anchor : CGPoint(x: picture.midX, y: picture.midY)
        let ratio = scale / currentScale
        let origin = CGPoint(
            x: anchor.x - (anchor.x - picture.minX) * ratio - (cardSize.width - size.width) / 2,
            y: anchor.y - (anchor.y - picture.minY) * ratio - toolbarHeight
        )
        return Placement(
            frame: confined(CGRect(origin: origin, size: cardSize), to: visibleFrame),
            imageSize: size
        )
    }

    /// On a display change, move the pin into view and shrink it only if it
    /// no longer fits.
    static func relocated(_ placement: Placement, in visibleFrame: CGRect) -> Placement {
        let scale = min(1, fittingScale(for: placement.imageSize, in: visibleFrame))
        let size = scaledSize(placement.imageSize, by: scale)
        let frame = CGRect(
            x: placement.frame.minX,
            y: placement.frame.maxY - cardSize(for: size).height,
            width: cardSize(for: size).width,
            height: cardSize(for: size).height
        )
        return Placement(frame: confined(frame, to: visibleFrame), imageSize: size)
    }

    private static func fittingScale(for size: CGSize, in visibleFrame: CGRect) -> CGFloat {
        min(
            (visibleFrame.width - 2 * border) / size.width,
            (visibleFrame.height - border - toolbarHeight) / size.height
        )
    }

    private static func scaledSize(_ size: CGSize, by scale: CGFloat) -> CGSize {
        CGSize(width: size.width * scale, height: size.height * scale)
    }

    private static func cardSize(for size: CGSize) -> CGSize {
        CGSize(width: max(size.width + 2 * border, minimumCardWidth), height: size.height + border + toolbarHeight)
    }

    private static func confined(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: max(visibleFrame.minX, min(frame.minX, visibleFrame.maxX - frame.width)),
            y: max(visibleFrame.minY, min(frame.minY, visibleFrame.maxY - frame.height)),
            width: frame.width,
            height: frame.height
        )
    }
}
