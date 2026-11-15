import CoreGraphics

enum ThumbnailLayout {
    /// The preview never grows beyond this.
    static let maximumPreviewSize = CGSize(width: 240, height: 160)
    /// Nor shrinks below this, so the buttons under it always fit.
    static let minimumPreviewSize = CGSize(width: 148, height: 48)

    static let toolbarHeight: CGFloat = 34
    static let margin: CGFloat = 16
    static let spacing: CGFloat = 10
    /// At most this many visible on one screen; older captures wait for room.
    static let maximumCount = 5

    /// The size of the preview for a screenshot of `imageSize` (in points):
    /// scaled down to fit, never scaled up, never smaller than the minimum.
    /// Of a very tall one it shows only the top (see `previewedPart`).
    static func previewSize(for imageSize: CGSize) -> CGSize {
        fittedSize(for: previewedPart(of: imageSize)?.size ?? imageSize)
    }

    /// The part of a screenshot of `imageSize` (in points, origin at the
    /// top-left corner) that its preview shows, or nil for all of it.
    ///
    /// A picture far taller than the preview, such as a scroll capture,
    /// would shrink to a thin strip in it. Its preview shows its top
    /// instead, in the shape of the largest preview, or at its real size
    /// if narrower.
    static func previewedPart(of imageSize: CGSize) -> CGRect? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let whole = fittedSize(for: imageSize)
        let fittedWidth = imageSize.width * whole.height / imageSize.height
        guard fittedWidth < whole.width / 2 else { return nil }
        let factor = min(maximumPreviewSize.width / imageSize.width, 1)
        let height = maximumPreviewSize.height / factor
        return CGRect(x: 0, y: 0, width: imageSize.width, height: min(height, imageSize.height))
    }

    private static func fittedSize(for imageSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return minimumPreviewSize }
        let factor = min(
            maximumPreviewSize.width / imageSize.width,
            maximumPreviewSize.height / imageSize.height,
            1
        )
        return CGSize(
            width: max((imageSize.width * factor).rounded(), minimumPreviewSize.width),
            height: max((imageSize.height * factor).rounded(), minimumPreviewSize.height)
        )
    }

    static func cardSize(for imageSize: CGSize) -> CGSize {
        let preview = previewSize(for: imageSize)
        return CGSize(width: preview.width, height: preview.height + toolbarHeight)
    }

    /// Frames for a stack of cards in the bottom-left corner of `area`,
    /// in AppKit screen coordinates (y grows upwards). The first size is the
    /// newest card and sits at the bottom.
    static func stackFrames(for cardSizes: [CGSize], in area: CGRect) -> [CGRect] {
        var y = area.minY + margin
        return cardSizes.map { size in
            let frame = CGRect(x: area.minX + margin, y: y, width: size.width, height: size.height)
            y += size.height + spacing
            return frame
        }
    }

    /// How many cards of such a stack fit inside `area`, counting from the
    /// newest (the first size). The rest would stick out of the top of the
    /// screen. Never less than one: the newest card always stays.
    static func fittingCount(for cardSizes: [CGSize], in area: CGRect) -> Int {
        var top = area.minY + margin
        var count = 0
        for size in cardSizes {
            top += size.height
            guard top <= area.maxY - margin else { break }
            count += 1
            top += spacing
        }
        return max(count, 1)
    }
}
