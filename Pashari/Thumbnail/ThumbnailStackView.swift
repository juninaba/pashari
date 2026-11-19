import AppKit

/// The thumbnails on one display, in the bottom-left corner of its visible
/// area.
///
/// One capture shows as a single card. More pile up behind the newest
/// one, like photos dropped on a desk, with a badge saying how many there
/// are. When the pointer rests on the pile, it spreads out into a column,
/// newest at the bottom, where every card can be used. Once the pointer
/// has left, the cards pile up again.
final class ThumbnailStackView: NSView {
    /// How long the pointer has to rest on the pile before it spreads out,
    /// so that merely passing over the corner does not set it off.
    static let spreadDelay: TimeInterval = 0.12
    /// How long after the pointer has left the cards pile up again.
    static let pileDelay: TimeInterval = 0.4
    /// Room around the cards for their shadows, their badge and the corners
    /// of turned cards.
    static let outset: CGFloat = 28

    /// Newest first. Cards that are fading away are no longer included.
    private(set) var cards: [ThumbnailCardView] = []
    private(set) var isSpread = false
    private var pendingCount = 0
    /// The display's visible frame, in screen coordinates.
    private var area = CGRect.zero
    private var leavingCount = 0

    private var hoverArea: NSTrackingArea?
    private var isPointerInside = false
    private var hoverTimer: Timer?
    /// Where the pointer is, in screen coordinates. Tests put it elsewhere.
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Shows `newCards` (newest first) in the corner of `area`, the
    /// display's visible frame. `pendingCount` is how many captures there are
    /// on this display, including those waiting for room.
    func show(_ newCards: [ThumbnailCardView], pendingCount: Int, in area: CGRect) {
        for card in cards where !newCards.contains(where: { $0 === card }) {
            card.removeFromSuperview()
        }
        let arriving = newCards.filter { $0.superview !== self }
        // Newer cards lie on top of older ones.
        for (index, card) in newCards.enumerated() where card.superview !== self {
            if let newer = newCards[..<index].last(where: { $0.superview === self }) {
                addSubview(card, positioned: .below, relativeTo: newer)
            } else {
                addSubview(card)
            }
        }

        let isSameArea = area == self.area
        cards = newCards
        self.pendingCount = pendingCount
        self.area = area
        if cards.count < 2 {
            isSpread = false
        }
        layoutCards(animated: isSameArea && window?.isVisible == true, arriving: arriving)

        if !cards.isEmpty {
            window?.orderFrontRegardless()
        } else if leavingCount == 0 {
            window?.orderOut(nil)
        }
    }

    /// Fades `card` away where it is. The other cards close the gap when
    /// `show` is called next.
    func dismiss(_ card: ThumbnailCardView) {
        cards.removeAll { $0 === card }
        guard card.superview === self else { return }
        leavingCount += 1
        card.fadeOut { [weak self, weak card] in
            card?.removeFromSuperview()
            guard let self else { return }
            leavingCount -= 1
            guard leavingCount == 0 else { return }
            if cards.isEmpty {
                window?.orderOut(nil)
            } else {
                fitWindow()
            }
        }
    }

    // MARK: - Layout

    /// The window's bottom-left corner. It stays put, and with it the
    /// cards, while the window grows and shrinks.
    private var origin: CGPoint {
        CGPoint(x: area.minX - Self.outset, y: area.minY - Self.outset)
    }

    /// Makes the window big enough for the cards both piled up and spread
    /// out, so that it stays the same while they move. While cards fade
    /// away, it only grows: shrinking would cut them off.
    private func fitWindow() {
        guard let window, !cards.isEmpty else { return }
        let sizes = cards.map(\.frame.size)
        let covered = (
            ThumbnailLayout.stackFrames(for: sizes, in: area)
                + ThumbnailLayout.pilePlacements(for: sizes, in: area).map(\.frame)
        ).reduce(CGRect.null) { $0.union($1) }
        var frame = CGRect(
            x: origin.x,
            y: origin.y,
            width: covered.maxX + Self.outset - origin.x,
            height: covered.maxY + Self.outset - origin.y
        )
        if leavingCount > 0, window.frame.origin == frame.origin {
            frame = frame.union(window.frame)
        }
        if window.frame != frame {
            window.setFrame(frame, display: false)
        }
    }

    private func layoutCards(animated: Bool, arriving: [ThumbnailCardView] = []) {
        defer { updateHoverTracking() }
        guard !cards.isEmpty else { return }
        fitWindow()

        let sizes = cards.map(\.frame.size)
        let column = ThumbnailLayout.stackFrames(for: sizes, in: area)
        let pile = ThumbnailLayout.pilePlacements(for: sizes, in: area)
        let origin = origin
        let spread = isSpread || cards.count == 1
        for (index, card) in cards.enumerated() {
            let placement = spread
                ? ThumbnailLayout.Placement(frame: column[index], angle: 0)
                : pile[index]
            let isArriving = arriving.contains { $0 === card }
            card.place(
                at: placement.frame.offsetBy(dx: -origin.x, dy: -origin.y),
                angle: placement.angle,
                animated: animated && !isArriving
            )
            if isArriving {
                if index == 0 { card.popIn() } else { card.fadeIn() }
            }
            let showsCount = index == 0 && !isSpread && pendingCount > 1
            card.setBadgeCount(showsCount ? pendingCount : nil, animated: animated)
        }
    }

    // MARK: - Spreading out and piling up

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateHoverTracking()
    }

    /// Watches the pointer over the cards as they lie now, the pile or the
    /// column (with the gaps in between).
    private func updateHoverTracking() {
        if let hoverArea {
            removeTrackingArea(hoverArea)
            self.hoverArea = nil
        }
        guard cards.count > 1, let window else {
            setPointerInside(false)
            return
        }
        let rect = cards.map(\.frame).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -6, dy: -6)
        let pointer = window.convertPoint(fromScreen: pointerLocation())
        let inside = rect.contains(convert(pointer, from: nil))
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways]
        if inside {
            options.insert(.assumeInside)
        }
        let area = NSTrackingArea(rect: rect, options: options, owner: self)
        addTrackingArea(area)
        hoverArea = area
        setPointerInside(inside)
    }

    override func mouseEntered(with event: NSEvent) {
        setPointerInside(true)
    }

    override func mouseExited(with event: NSEvent) {
        setPointerInside(false)
    }

    /// A click on the pile outside the newest card's buttons spreads it out
    /// at once.
    override func mouseDown(with event: NSEvent) {
        setSpread(true)
    }

    private func setPointerInside(_ inside: Bool) {
        isPointerInside = inside
        hoverTimer?.invalidate()
        hoverTimer = nil
        guard cards.count > 1, inside != isSpread else { return }
        let timer = Timer(
            timeInterval: inside ? Self.spreadDelay : Self.pileDelay,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hoverTimerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func hoverTimerFired() {
        hoverTimer = nil
        // Piling up under a drag would move the card it started from.
        if !isPointerInside, cards.contains(where: \.previewView.isDragging) {
            setPointerInside(false)
            return
        }
        setSpread(isPointerInside)
    }

    func setSpread(_ spread: Bool) {
        guard cards.count > 1, spread != isSpread else { return }
        isSpread = spread
        layoutCards(animated: true)
    }
}
