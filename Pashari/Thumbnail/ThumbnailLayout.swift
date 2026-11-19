import CoreGraphics

enum ThumbnailLayout {
    /// The preview never grows beyond this.
    static let maximumPreviewSize = CGSize(width: 240, height: 160)
    /// Nor shrinks below this, so the buttons under it always fit.
    static let minimumPreviewSize = CGSize(width: 148, height: 48)

    /// A card is a little instant photo: paper around the preview, narrow
    /// at the top and sides, and wide at the bottom, where the buttons are.
    static let paperBorder: CGFloat = 8
    static let toolbarHeight: CGFloat = 36
    static let margin: CGFloat = 16
    static let spacing: CGFloat = 12
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
        return CGSize(
            width: preview.width + paperBorder * 2,
            height: preview.height + paperBorder + toolbarHeight
        )
    }

    /// Where the preview sits on a card of `cardSize`, in the card's own
    /// coordinates (y grows upwards).
    static func previewFrame(inCardOf cardSize: CGSize) -> CGRect {
        CGRect(
            x: paperBorder,
            y: toolbarHeight,
            width: cardSize.width - paperBorder * 2,
            height: cardSize.height - paperBorder - toolbarHeight
        )
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

    // MARK: - Pile

    /// Where a card lies, and how far it is turned (in radians,
    /// anticlockwise, around its centre).
    struct Placement: Equatable {
        var frame: CGRect
        var angle: CGFloat
    }

    /// How each card behind the newest one lies on the pile: how far its
    /// top rises above every card in front of it, how far it is moved
    /// sideways, and how far it is turned.
    private static let pileSlots: [(rise: CGFloat, shift: CGFloat, degrees: CGFloat)] = [
        (rise: 10, shift: -2, degrees: -4),
        (rise: 8, shift: 6, degrees: 5),
        (rise: 6, shift: 1, degrees: -2),
        (rise: 4, shift: 4, degrees: 3),
    ]

    /// The cards piled up in the bottom-left corner of `area`, like photos
    /// dropped on a desk. The newest (the first size) lies upright where the
    /// first card of the stack would be. Each older one lies behind the
    /// others, turned a little, with its top showing above all of them,
    /// however tall they are. None reaches below the newest card.
    static func pilePlacements(for cardSizes: [CGSize], in area: CGRect) -> [Placement] {
        guard let front = cardSizes.first else { return [] }
        let corner = CGPoint(x: area.minX + margin, y: area.minY + margin)
        var pileTop = corner.y + front.height
        return cardSizes.enumerated().map { index, size in
            guard index > 0 else {
                return Placement(frame: CGRect(origin: corner, size: size), angle: 0)
            }
            let slot = pileSlots[(index - 1) % pileSlots.count]
            let bottom = max(corner.y, pileTop + slot.rise - size.height)
            pileTop = bottom + size.height
            return Placement(
                frame: CGRect(x: corner.x + slot.shift, y: bottom, width: size.width, height: size.height),
                angle: slot.degrees * .pi / 180
            )
        }
    }
}
