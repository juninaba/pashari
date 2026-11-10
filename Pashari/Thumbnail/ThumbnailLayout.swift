import CoreGraphics

/// Sizes and positions of the floating thumbnails. Plain arithmetic, kept
/// apart from the windows so it can be tested.
enum ThumbnailLayout {
    /// The preview never grows beyond this.
    static let maximumPreviewSize = CGSize(width: 240, height: 160)
    /// Nor shrinks below this, so the buttons under it always fit.
    static let minimumPreviewSize = CGSize(width: 148, height: 48)

    static let toolbarHeight: CGFloat = 34
    /// Distance from the screen's edges.
    static let margin: CGFloat = 16
    /// Gap between stacked thumbnails.
    static let spacing: CGFloat = 10
    /// More than this and the oldest thumbnail gives way to the newest.
    static let maximumCount = 5

    /// The size of the preview for a screenshot of `imageSize` (in points):
    /// scaled down to fit, never scaled up, never smaller than the minimum.
    static func previewSize(for imageSize: CGSize) -> CGSize {
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

    /// The whole card: preview plus the row of buttons under it.
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
}
