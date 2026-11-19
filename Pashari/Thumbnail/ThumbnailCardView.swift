import AppKit
import QuartzCore

/// One capture's thumbnail: a little instant photo with its buttons on the
/// wide bottom edge of the paper.
///
/// What it shows is drawn by layers of its own, `paper` and the ones on
/// it, so that a pile can turn and move the photo freely. (AppKit puts a
/// view's own layer straight again whenever the view moves.) The views on
/// top are see-through and always upright: they only take clicks and
/// drags, and tell VoiceOver what is there.
final class ThumbnailCardView: NSView {
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onAnnotate: (() -> Void)?
    var onClose: (() -> Void)?

    let previewView: ThumbnailPreviewView
    private let toolbar: NSView
    private var actionButtons: [ThumbnailButton] = []

    /// The photo as it shows on screen.
    let paper = CALayer()
    private let picture = CALayer()
    private let badge = CALayer()
    private let badgeLabel = CATextLayer()
    private(set) var badgeCount: Int?

    /// Set while the card fades away; it takes no more clicks by then.
    private(set) var isLeaving = false

    init(imageSize: CGSize) {
        let size = ThumbnailLayout.cardSize(for: imageSize)
        let previewFrame = ThumbnailLayout.previewFrame(inCardOf: size)
        previewView = ThumbnailPreviewView(frame: previewFrame)
        toolbar = NSView(frame: CGRect(x: 0, y: 0, width: size.width, height: ThumbnailLayout.toolbarHeight))
        super.init(frame: CGRect(origin: .zero, size: size))

        wantsLayer = true
        layer?.addSublayer(paper)
        CALayer.withoutAnimation {
            setUpPaper(previewFrame: previewFrame)
            setUpBadge()
        }
        updateColors()
        addSubview(previewView)
        addSubview(toolbar)
        makeButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ThumbnailCardView is created in code only")
    }

    /// The picture "develops" on the paper when it is ready, like an
    /// instant photo does.
    func show(_ image: CGImage) {
        previewView.show(image)
        CATransaction.begin()
        CATransaction.setAnimationDuration(ThumbnailMotion.isReduced ? 0 : 0.35)
        picture.contents = image
        CATransaction.commit()
    }

    var hasPicture: Bool { picture.contents != nil }

    func setActionsEnabled(_ enabled: Bool) {
        actionButtons.forEach { $0.isEnabled = enabled }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isLeaving ? nil : super.hitTest(point)
    }

    /// Where the photo shows now, in the superview. While it glides to a
    /// new place, that is not where the card is laid out.
    var shownFrame: CGRect {
        (paper.presentation() ?? paper).frame.offsetBy(dx: frame.minX, dy: frame.minY)
    }

    /// Where `point` (in the superview), on the card as it shows on screen
    /// now, lies on the card as it is laid out; nil where the card does not
    /// show. The two differ while the photo glides to a new place.
    func laidOutPoint(forShownPoint point: CGPoint) -> CGPoint? {
        guard !isLeaving else { return nil }
        let shown = (paper.presentation() ?? paper).transform
        guard CATransform3DIsAffine(shown) else { return nil }
        // The paper turns and moves around its centre, the card's centre.
        let fromCenter = CGPoint(x: point.x - frame.midX, y: point.y - frame.midY)
            .applying(CATransform3DGetAffineTransform(shown).inverted())
        let onCard = CGPoint(x: bounds.midX + fromCenter.x, y: bounds.midY + fromCenter.y)
        guard bounds.contains(onCard) else { return nil }
        return CGPoint(x: frame.minX + onCard.x, y: frame.minY + onCard.y)
    }

    // MARK: - The look

    private func setUpPaper(previewFrame: CGRect) {
        paper.frame = bounds
        paper.cornerRadius = ThumbnailStyle.cornerRadius
        paper.cornerCurve = .continuous
        paper.borderWidth = 0.5
        paper.shadowColor = CGColor(gray: 0, alpha: 1)
        paper.shadowOpacity = 0.32
        paper.shadowRadius = 9
        paper.shadowOffset = CGSize(width: 0, height: -4)
        // Given the shape, Core Animation does not have to work it out
        // from the pixels, which would take an extra pass for every frame.
        paper.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: ThumbnailStyle.cornerRadius,
            cornerHeight: ThumbnailStyle.cornerRadius,
            transform: nil
        )

        picture.frame = previewFrame
        picture.cornerRadius = ThumbnailStyle.pictureCornerRadius
        picture.cornerCurve = .continuous
        picture.masksToBounds = true
        picture.contentsGravity = .resizeAspect
        picture.borderWidth = 0.5
        paper.addSublayer(picture)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// Paints the photo for the card's appearance, light or dark.
    private func updateColors() {
        let colors = ThumbnailStyle.colors(for: effectiveAppearance)
        CALayer.withoutAnimation {
            paper.backgroundColor = colors.paper
            paper.borderColor = colors.edge
            picture.backgroundColor = colors.pictureBackground
            picture.borderColor = colors.pictureEdge
            // A ring of paper sets the badge off from the photo under it.
            badge.borderColor = colors.paper
        }
    }

    private func setUpBadge() {
        badge.backgroundColor = ThumbnailStyle.badge
        badge.borderWidth = 2
        badge.shadowColor = CGColor(gray: 0, alpha: 1)
        badge.shadowOpacity = 0.25
        badge.shadowRadius = 3
        badge.shadowOffset = CGSize(width: 0, height: -1)
        badge.opacity = 0

        let font = NSFont.systemFont(ofSize: 12, weight: .bold)
        badgeLabel.font = font
        badgeLabel.fontSize = font.pointSize
        badgeLabel.foregroundColor = CGColor(gray: 1, alpha: 1)
        badgeLabel.alignmentMode = .center
        // Text is drawn as pixels; two per point keeps it sharp on Retina
        // displays and is merely sampled down on others.
        badgeLabel.contentsScale = 2
        badge.addSublayer(badgeLabel)
        paper.addSublayer(badge)
    }

    /// Shows how many captures there are, in the top right corner, or hides
    /// the badge for nil.
    func setBadgeCount(_ count: Int?, animated: Bool) {
        guard count != badgeCount else { return }
        let wasShown = badgeCount != nil
        badgeCount = count
        if let count {
            let font = NSFont.systemFont(ofSize: 12, weight: .bold)
            let text = count > 99 ? "99+" : "\(count)"
            let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
            let height: CGFloat = 22
            let width = max(height, textWidth + 12)
            let lineHeight = ceil(font.ascender - font.descender)
            CALayer.withoutAnimation {
                badge.bounds = CGRect(x: 0, y: 0, width: width, height: height)
                badge.cornerRadius = height / 2
                badge.shadowPath = CGPath(
                    roundedRect: badge.bounds,
                    cornerWidth: height / 2,
                    cornerHeight: height / 2,
                    transform: nil
                )
                badge.position = CGPoint(x: bounds.maxX - 4, y: bounds.maxY - 4)
                badgeLabel.string = text
                badgeLabel.frame = CGRect(x: 0, y: (height - lineHeight) / 2, width: width, height: lineHeight)
            }
        }
        let shown = count != nil
        guard shown != wasShown else { return }
        CALayer.withoutAnimation { badge.opacity = shown ? 1 : 0 }
        guard animated, !ThumbnailMotion.isReduced else { return }
        if shown {
            badge.add(ThumbnailMotion.fade(from: 0, to: 1, duration: 0.15), forKey: "fade")
            badge.add(
                ThumbnailMotion.spring(
                    keyPath: "transform.scale",
                    from: 0.4,
                    to: 1,
                    bouncy: true
                ),
                forKey: "pop"
            )
        } else {
            badge.add(ThumbnailMotion.fade(from: 1, to: 0, duration: 0.12), forKey: "fade")
        }
    }

    // MARK: - Moving

    /// Puts the card at `frame` (in its superview), turned by `angle`.
    ///
    /// The see-through views jump straight there. With `animated`, the
    /// photo glides from wherever it shows now, even halfway through
    /// another move, so the two meet when the move ends.
    func place(at frame: CGRect, angle: CGFloat, animated: Bool) {
        let oldOrigin = self.frame.origin
        let shown = paper.presentation()?.transform ?? paper.transform
        setFrameOrigin(frame.origin)
        let target = CATransform3DMakeRotation(angle, 0, 0, 1)
        CALayer.withoutAnimation { paper.transform = target }

        guard animated, !ThumbnailMotion.isReduced else {
            paper.removeAnimation(forKey: "place")
            return
        }
        // Where the photo shows now, seen from where the card is now.
        let from = CATransform3DConcat(
            shown,
            CATransform3DMakeTranslation(oldOrigin.x - frame.minX, oldOrigin.y - frame.minY, 0)
        )
        guard !CATransform3DEqualToTransform(from, target) else { return }
        paper.add(
            ThumbnailMotion.spring(
                keyPath: "transform",
                from: NSValue(caTransform3D: from),
                to: NSValue(caTransform3D: target)
            ),
            forKey: "place"
        )
    }

    /// For a new capture: the photo pops up from the corner of the screen
    /// with a little bounce.
    func popIn() {
        guard !ThumbnailMotion.isReduced else { return fadeIn() }
        var from = CATransform3DMakeTranslation(-28, -44, 0)
        from = CATransform3DRotate(from, -9 * .pi / 180, 0, 0, 1)
        from = CATransform3DScale(from, 0.5, 0.5, 1)
        paper.add(
            ThumbnailMotion.spring(
                keyPath: "transform",
                from: NSValue(caTransform3D: from),
                to: NSValue(caTransform3D: paper.transform),
                bouncy: true
            ),
            forKey: "place"
        )
        paper.add(ThumbnailMotion.fade(from: 0, to: 1, duration: 0.16), forKey: "fade")
    }

    func fadeIn() {
        paper.add(ThumbnailMotion.fade(from: 0, to: 1, duration: 0.2), forKey: "fade")
    }

    /// Fades the photo away, shrinking it a little, then calls `completion`.
    func fadeOut(completion: @escaping () -> Void) {
        isLeaving = true
        setBadgeCount(nil, animated: false)
        guard !ThumbnailMotion.isReduced else {
            CALayer.withoutAnimation { paper.opacity = 0 }
            completion()
            return
        }
        let shown = paper.presentation()?.transform ?? paper.transform
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        CALayer.withoutAnimation {
            paper.opacity = 0
            paper.transform = CATransform3DScale(shown, 0.85, 0.85, 1)
        }
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = NSValue(caTransform3D: shown)
        shrink.toValue = NSValue(caTransform3D: paper.transform)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = paper.presentation()?.opacity ?? 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [shrink, fade]
        group.duration = 0.18
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        paper.add(group, forKey: "place")
        paper.removeAnimation(forKey: "fade")
        CATransaction.commit()
    }

    // MARK: - Buttons

    private func makeButtons() {
        let buttons = [
            ThumbnailButton(
                symbolName: "doc.on.doc",
                label: String(localized: "Copy"),
                action: { [weak self] in self?.onCopy?() }
            ),
            ThumbnailButton(
                symbolName: "square.and.arrow.down",
                label: String(localized: "Save"),
                action: { [weak self] in self?.onSave?() }
            ),
            ThumbnailButton(
                symbolName: "pencil.and.outline",
                label: String(localized: "Annotate"),
                action: { [weak self] in self?.onAnnotate?() }
            ),
            ThumbnailButton(
                symbolName: "xmark",
                label: String(localized: "Close"),
                action: { [weak self] in self?.onClose?() }
            ),
        ]

        actionButtons = buttons
        let buttonWidth = bounds.width / CGFloat(buttons.count)
        for (index, button) in buttons.enumerated() {
            let frame = CGRect(
                x: CGFloat(index) * buttonWidth,
                y: 0,
                width: buttonWidth,
                height: ThumbnailLayout.toolbarHeight
            )
            button.frame = frame
            toolbar.addSubview(button)
            // The toolbar sits at the card's origin, so the button's frame
            // is also where its icon goes on the paper.
            CALayer.withoutAnimation { button.placeLook(in: frame) }
            paper.addSublayer(button.look)
        }
    }
}

/// A see-through button over one of the card's icons. The icon, and the
/// highlight under it while the pointer is over it, are layers on the
/// card's photo (`look`), so that they move and turn with it.
final class ThumbnailButton: NSButton {
    let look = CALayer()
    private let highlight = CALayer()
    private let icon = CALayer()
    private let symbolName: String
    private let handler: () -> Void
    private var isHovered = false
    private var isPressed = false

    init(symbolName: String, label: String, action handler: @escaping () -> Void) {
        self.symbolName = symbolName
        self.handler = handler
        super.init(frame: .zero)

        title = ""
        isBordered = false
        isTransparent = true
        toolTip = label
        setAccessibilityLabel(label)
        target = self
        action = #selector(performAction)

        CALayer.withoutAnimation {
            highlight.cornerRadius = 8
            highlight.cornerCurve = .continuous
            highlight.opacity = 0
            look.addSublayer(highlight)
            icon.contentsGravity = .resizeAspect
            look.addSublayer(icon)
        }
        updateColors()
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ThumbnailButton is created in code only")
    }

    func placeLook(in frame: CGRect) {
        look.frame = frame
        let center = CGPoint(x: frame.width / 2, y: frame.height / 2)
        highlight.bounds = CGRect(x: 0, y: 0, width: min(frame.width - 6, 34), height: 26)
        highlight.position = center
        icon.position = center
    }

    override var isEnabled: Bool {
        didSet { updateLook(animated: true) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateLook(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateLook(animated: true)
    }

    /// Follows the mouse until it goes up, and acts if that is over the
    /// button as it shows on screen. NSButton's own tracking would test the
    /// button's frame, which jumps ahead while the photo glides to a new
    /// place, and ignore a click on the button the user sees.
    override func mouseDown(with event: NSEvent) {
        // The second click of a double-click would land on the card that
        // takes this one's place once it goes: Close would then throw away
        // a capture nobody meant to.
        guard isEnabled, event.clickCount < 2, let window else { return }
        var isOver = true
        setPressed(true)
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            isOver = showsButton(at: Self.location(of: next, in: window))
            setPressed(isOver)
            if next.type == .leftMouseUp { break }
        }
        setPressed(false)
        if isOver {
            sendAction(action, to: target)
        }
    }

    /// Where `event` happened, in `window`. An event can come with another
    /// window, or none, and then gives its position in that window or on
    /// the screen.
    private static func location(of event: NSEvent, in window: NSWindow) -> NSPoint {
        if event.window === window {
            return event.locationInWindow
        }
        let onScreen = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        return window.convertPoint(fromScreen: onScreen)
    }

    /// Whether the button shows at `location`, in the window, and is not
    /// covered by another card: the window's hit test knows where the cards
    /// show and which lies on top.
    private func showsButton(at location: NSPoint) -> Bool {
        guard let content = window?.contentView else { return false }
        let point = content.superview?.convert(location, from: nil) ?? location
        return content.hitTest(point) === self
    }

    private func setPressed(_ pressed: Bool) {
        guard pressed != isPressed else { return }
        isPressed = pressed
        updateLook(animated: !pressed)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// The ink of the icon and its highlight, for the card's appearance.
    private var ink: NSColor {
        ThumbnailStyle.colors(for: effectiveAppearance).ink
    }

    private func updateColors() {
        if let image = Self.icon(named: symbolName, in: ink) {
            CALayer.withoutAnimation {
                icon.contents = image.image
                icon.bounds = CGRect(origin: .zero, size: image.size)
            }
        }
        updateLook(animated: false)
    }

    private func updateLook(animated: Bool) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.12)
        } else {
            CATransaction.setDisableActions(true)
        }
        let isLit = isEnabled && (isHovered || isPressed)
        highlight.opacity = isLit ? 1 : 0
        highlight.backgroundColor = ink.withAlphaComponent(isPressed ? 0.2 : 0.1).cgColor
        icon.opacity = isEnabled ? 1 : 0.35
        CATransaction.commit()
    }

    @objc private func performAction() {
        handler()
    }

    // MARK: - Icons

    private struct IconKey: Hashable {
        let symbolName: String
        let ink: NSColor
    }

    private static var icons: [IconKey: (image: CGImage, size: CGSize)] = [:]

    /// The symbol in `ink`, drawn at twice its size in points: sharp on
    /// Retina displays, and merely sampled down on others.
    private static func icon(named symbolName: String, in ink: NSColor) -> (image: CGImage, size: CGSize)? {
        let key = IconKey(symbolName: symbolName, ink: ink)
        if let icon = icons[key] { return icon }
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
        guard
            let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        else {
            return nil
        }
        let size = symbol.size
        let scale: CGFloat = 2
        guard let context = CGContext(
            data: nil,
            width: Int((size.width * scale).rounded(.up)),
            height: Int((size.height * scale).rounded(.up)),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        symbol.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        icons[key] = (image, size)
        return (image, size)
    }
}
