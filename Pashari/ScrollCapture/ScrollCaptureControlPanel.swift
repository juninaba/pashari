import AppKit

/// The small bar next to the area while it is recorded: the picture's size
/// so far, a hint, and the Cancel and Done buttons (Escape and Return).
///
/// A non-activating panel like the selection overlays, so the app being
/// scrolled stays the active one.
final class ScrollCaptureControlPanel: NSPanel {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?

    private let sizeLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let cancelButton = PanelButton(title: String(localized: "Cancel"))
    private let doneButton = PanelButton(title: String(localized: "Done"))

    private static let scrollHint = String(localized: "Scroll to capture more")
    private static let lostHint = String(localized: "Scroll back a little, then more slowly")
    private static let gap: CGFloat = 12

    init() {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = OverlayPanel.windowLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        hidesOnDeactivate = false
        worksWhenModal = true
        isReleasedWhenClosed = false
        // It may sit over something the user wants to see.
        isMovableByWindowBackground = true
        appearance = NSAppearance(named: .darkAqua)

        let content = makeContent()
        contentView = content
        setContentSize(content.fittingSize)
    }

    // Borderless windows refuse keyboard focus by default. This one needs it
    // for Return and Escape.
    override var canBecomeKey: Bool { true }

    /// `size` is the picture's size in points.
    func show(size: CGSize, isLost: Bool) {
        sizeLabel.stringValue = "\(Int(size.width)) × \(Int(size.height))"
        hintLabel.stringValue = isLost ? Self.lostHint : Self.scrollHint
        hintLabel.textColor = isLost ? .systemYellow : .secondaryLabelColor
    }

    /// Once the user has decided, the buttons have done their part.
    func disableButtons() {
        cancelButton.isEnabled = false
        doneButton.isEnabled = false
    }

    /// Centred under the area, or over it when there is no room below, or
    /// else inside its bottom edge. Everything is in AppKit screen
    /// coordinates, where y grows upwards.
    static func frame(ofSize size: CGSize, nextTo area: CGRect, in visibleFrame: CGRect) -> CGRect {
        var origin = CGPoint(x: area.midX - size.width / 2, y: area.minY - gap - size.height)
        if origin.y < visibleFrame.minY {
            origin.y = area.maxY + gap
            if origin.y + size.height > visibleFrame.maxY {
                origin.y = max(area.minY, visibleFrame.minY) + gap
            }
        }
        origin.x = min(max(origin.x, visibleFrame.minX + gap), visibleFrame.maxX - gap - size.width)
        return CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
    }

    private func makeContent() -> NSView {
        let background = NSVisualEffectView()
        // The same frosted look as the thumbnails. `.active` keeps it from
        // turning grey because Pashari is not the active app.
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        sizeLabel.textColor = .labelColor
        hintLabel.font = .systemFont(ofSize: 12)

        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.handler = { [weak self] in self?.onCancel?() }
        doneButton.keyEquivalent = "\r"
        doneButton.handler = { [weak self] in self?.onDone?() }

        let stack = NSStackView(views: [sizeLabel, hintLabel, cancelButton, doneButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.setCustomSpacing(16, after: sizeLabel)
        stack.setCustomSpacing(20, after: hintLabel)
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)

        // Wide enough for every text they can show, so that the bar keeps
        // its size, and its buttons their place, while the texts change.
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            sizeLabel.widthAnchor.constraint(equalToConstant: Self.width(of: ["00000 × 00000"], in: sizeLabel)),
            hintLabel.widthAnchor.constraint(
                equalToConstant: Self.width(of: [Self.scrollHint, Self.lostHint], in: hintLabel)
            ),
        ])
        show(size: .zero, isLost: false)
        return background
    }

    private static func width(of texts: [String], in label: NSTextField) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: label.font as Any]
        return ceil(texts.map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0) + 4
    }
}

/// A push button that works on the first click, even while another app is
/// active.
private final class PanelButton: NSButton {
    var handler: (() -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        target = self
        action = #selector(performAction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PanelButton is created in code only")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func performAction() {
        handler?()
    }
}
