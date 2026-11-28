import AppKit
import QuartzCore

/// A screenshot can stay above the user's work without becoming its key
/// window. Like thumbnails, these panels follow the user across Spaces
/// (including full-screen apps) and stay out of captures.
final class PinnedScreenshotPanel: NSPanel, NSWindowDelegate {
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onAnnotate: (() -> Void)?
    var onUnpin: (() -> Void)?
    var fileURL: (() -> URL?)?
    var onDrop: (() -> Void)?
    var onGeometryChange: (() -> Void)?

    private let originalSize: CGSize
    private let card: PinnedScreenshotCard

    private var placement: PinnedScreenshotLayout.Placement {
        PinnedScreenshotLayout.Placement(frame: frame, imageSize: card.imageSize)
    }

    var imageFrame: CGRect { placement.imageFrame }

    init(imageSize: CGSize, placement: PinnedScreenshotLayout.Placement) {
        originalSize = imageSize
        card = PinnedScreenshotCard(placement: placement)
        super.init(
            contentRect: placement.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = String(localized: "Pinned Screenshot")
        level = ThumbnailPanel.windowLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        delegate = self
        contentView = card
        card.setUpActions(for: self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setActionsEnabled(_ enabled: Bool) {
        card.setActionsEnabled(enabled)
    }

    func show(_ image: CGImage) {
        card.show(image)
        invalidateShadow()
    }

    func place(in visibleFrame: CGRect) {
        apply(PinnedScreenshotLayout.relocated(placement, in: visibleFrame))
    }

    fileprivate func zoom(by factor: CGFloat, at locationInWindow: CGPoint) {
        guard let screen else { return }
        apply(PinnedScreenshotLayout.zoomed(
            placement,
            originalSize: originalSize,
            by: factor,
            at: convertPoint(toScreen: locationInWindow),
            in: screen.visibleFrame
        ))
    }

    fileprivate func adjustOpacity(by delta: CGFloat) {
        alphaValue = min(max(alphaValue + delta, 0.2), 1)
    }

    private func apply(_ placement: PinnedScreenshotLayout.Placement) {
        card.imageSize = placement.imageSize
        setFrame(placement.frame, display: true)
        onGeometryChange?()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        onGeometryChange?()
    }

    func windowDidMove(_ notification: Notification) {
        onGeometryChange?()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        onGeometryChange?()
    }
}

private final class PinnedScreenshotCard: NSView {
    var imageSize: CGSize {
        didSet { needsLayout = true }
    }

    private let picture = CALayer()
    private let controls = CALayer()
    private let fileDrag = ThumbnailPreviewView(frame: .zero)
    private let fileIcon = NSImageView(frame: .zero)
    private var buttons: [ThumbnailButton] = []
    private var hoverTracking: NSTrackingArea?
    private var actionsEnabled = true
    private var isHovered = false

    init(placement: PinnedScreenshotLayout.Placement) {
        imageSize = placement.imageSize
        super.init(frame: CGRect(origin: .zero, size: placement.frame.size))
        wantsLayer = true
        layer?.cornerRadius = ThumbnailStyle.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.addSublayer(picture)
        layer?.addSublayer(controls)

        picture.frame = placement.imageBounds
        picture.cornerRadius = ThumbnailStyle.pictureCornerRadius
        picture.cornerCurve = .continuous
        picture.masksToBounds = true
        picture.contentsGravity = .resizeAspect
        picture.borderWidth = 0.5
        controls.opacity = 0

        toolTip = String(localized: "Drag to move. Scroll or pinch to resize. Option-scroll to change opacity.")
        let dragLabel = String(localized: "Drag File")
        fileDrag.toolTip = dragLabel
        fileDrag.setAccessibilityElement(true)
        fileDrag.setAccessibilityRole(.image)
        fileDrag.setAccessibilityLabel(dragLabel)
        fileIcon.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        fileIcon.imageScaling = .scaleNone
        fileIcon.setAccessibilityElement(false)
        fileIcon.alphaValue = 0
        addSubview(fileIcon)
        addSubview(fileDrag)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PinnedScreenshotCard is created in code only")
    }

    func setUpActions(for panel: PinnedScreenshotPanel) {
        buttons = [
            ThumbnailButton(symbolName: "doc.on.doc", label: String(localized: "Copy")) { [weak panel] in
                panel?.onCopy?()
            },
            ThumbnailButton(symbolName: "square.and.arrow.down", label: String(localized: "Save")) { [weak panel] in
                panel?.onSave?()
            },
            ThumbnailButton(symbolName: "pencil.and.outline", label: String(localized: "Annotate")) { [weak panel] in
                panel?.onAnnotate?()
            },
            ThumbnailButton(symbolName: "xmark", label: String(localized: "Unpin")) { [weak panel] in
                panel?.onUnpin?()
            },
        ]
        for button in buttons {
            addSubview(button)
            controls.addSublayer(button.look)
        }
        fileDrag.fileURL = { [weak self, weak panel] in
            guard self?.actionsEnabled == true else { return nil }
            return panel?.fileURL?()
        }
        fileDrag.onDrop = { [weak panel] in panel?.onDrop?() }
        fileDrag.onDragEnd = { [weak self] in self?.refreshHoverAfterDrag() }
        needsLayout = true
    }

    func setActionsEnabled(_ enabled: Bool) {
        actionsEnabled = enabled
        buttons.forEach { $0.isEnabled = enabled }
        updateControls()
    }

    func show(_ image: CGImage) {
        let isFirstPicture = picture.contents == nil
        fileDrag.show(image)
        CALayer.withoutAnimation { picture.contents = image }
        if isFirstPicture && !ThumbnailMotion.isReduced {
            picture.add(ThumbnailMotion.fade(from: 0, to: 1, duration: 0.2), forKey: "develop")
        }
    }

    override func layout() {
        super.layout()
        let placement = PinnedScreenshotLayout.Placement(frame: bounds, imageSize: imageSize)
        let width = min(bounds.width, PinnedScreenshotLayout.maximumToolbarWidth)
        let buttonWidth = width / CGFloat(buttons.count + 1)
        func buttonFrame(at index: Int) -> CGRect {
            CGRect(
                x: (bounds.width - width) / 2 + CGFloat(index) * buttonWidth,
                y: 0,
                width: buttonWidth,
                height: PinnedScreenshotLayout.toolbarHeight
            )
        }
        CALayer.withoutAnimation {
            picture.frame = placement.imageBounds
            controls.frame = bounds
            for (index, button) in buttons.enumerated() {
                // The file-drag handle sits between Annotate and Unpin.
                button.frame = buttonFrame(at: index == buttons.count - 1 ? index + 1 : index)
                button.placeLook(in: button.frame)
            }
        }
        fileDrag.frame = buttonFrame(at: buttons.count - 1)
        fileIcon.frame = fileDrag.frame
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        let colors = ThumbnailStyle.colors(for: effectiveAppearance)
        CALayer.withoutAnimation {
            layer?.backgroundColor = colors.paper
            layer?.borderColor = colors.edge
            picture.backgroundColor = colors.pictureBackground
            picture.borderColor = colors.pictureEdge
        }
        fileIcon.contentTintColor = colors.ink
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateControls()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateControls()
    }

    private func refreshHoverAfterDrag() {
        // Dragging out of the card can skip mouseExited.
        guard let window else { return }
        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        isHovered = bounds.contains(convert(point, from: nil))
        updateControls()
    }

    private func updateControls() {
        let opacity: Float = isHovered ? 1 : 0
        let current = controls.presentation()?.opacity ?? controls.opacity
        CALayer.withoutAnimation { controls.opacity = opacity }
        if current != opacity && !ThumbnailMotion.isReduced {
            controls.add(ThumbnailMotion.fade(from: current, to: opacity, duration: 0.12), forKey: "hover")
        }
        fileIcon.alphaValue = isHovered ? (actionsEnabled ? 1 : 0.35) : 0
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func magnify(with event: NSEvent) {
        (window as? PinnedScreenshotPanel)?.zoom(by: 1 + event.magnification, at: event.locationInWindow)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty, event.scrollingDeltaY != 0 else { return }
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.008 : 0.1)
        if event.modifierFlags.contains(.option) {
            (window as? PinnedScreenshotPanel)?.adjustOpacity(by: delta)
        } else {
            (window as? PinnedScreenshotPanel)?.zoom(by: exp(delta), at: event.locationInWindow)
        }
    }
}
