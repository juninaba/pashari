import AppKit

/// The small bar next to the area while it is recorded: the picture's size
/// so far, a hint, Cancel and Done (Escape and Return), and a compact preview
/// of the bottom of the stitched picture.
///
/// A non-activating panel like the selection overlays, so the app being
/// scrolled stays the active one.
final class ScrollCaptureControlPanel: NSPanel {
    enum Status {
        /// Recording has not begun yet. Whatever scrolls by now would be
        /// missing from the top of the picture.
        case preparing
        case recording
        /// The frames cannot be placed; see `ScrollRecorder.Progress`.
        case lost
    }

    static let previewHeight: CGFloat = 108

    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?

    /// Size of the preview well in points.
    var previewSize: CGSize { previewView.bounds.size }
    /// The tail image currently shown, if any.
    var previewImage: CGImage? { previewView.image }

    private let sizeLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let cancelButton = PanelButton(title: String(localized: "Cancel"))
    private let doneButton = PanelButton(title: String(localized: "Done"))
    private let previewView = TailPreviewView()

    private static let preparingHint = String(localized: "Getting ready…")
    private static let scrollHint = String(localized: "Scroll to capture more")
    private static let lostHint = String(localized: "Scroll back a little, then more slowly")

    init() {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 160),
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
        content.layoutSubtreeIfNeeded()
        show(size: .zero, status: .preparing)
    }

    // Borderless windows refuse keyboard focus by default. This one needs it
    // for Return and Escape.
    override var canBecomeKey: Bool { true }

    /// `size` is the picture's size in points. Passing `nil` for `preview`
    /// keeps the last shown tail image.
    func show(size: CGSize, status: Status, preview: CGImage? = nil, scale: CGFloat = 1) {
        sizeLabel.stringValue = "\(Int(size.width)) × \(Int(size.height))"
        switch status {
        case .preparing:
            hintLabel.stringValue = Self.preparingHint
            hintLabel.textColor = .secondaryLabelColor
        case .recording:
            hintLabel.stringValue = Self.scrollHint
            hintLabel.textColor = .secondaryLabelColor
        case .lost:
            hintLabel.stringValue = Self.lostHint
            hintLabel.textColor = .systemYellow
        }
        previewView.setLost(status == .lost)
        if let preview {
            previewView.show(preview, scale: scale)
        }
    }

    /// Once the user has decided, the buttons have done their part.
    func disableButtons() {
        cancelButton.isEnabled = false
        doneButton.isEnabled = false
    }

    static func previewImageRect(pixelSize: CGSize, scale: CGFloat, in bounds: CGRect) -> CGRect {
        TailPreviewView.imageRect(pixelSize: pixelSize, scale: scale, in: bounds)
    }

    private func makeContent() -> NSView {
        let background = NSVisualEffectView()
        // The frosted look of the system's floating panels. `.active` keeps it from
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

        previewView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(previewView)

        // Wide enough for every text they can show, so that the bar keeps
        // its size, and its buttons their place, while the texts change.
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            sizeLabel.widthAnchor.constraint(equalToConstant: Self.width(of: ["00000 × 00000"], in: sizeLabel)),
            hintLabel.widthAnchor.constraint(
                equalToConstant: Self.width(of: [Self.preparingHint, Self.scrollHint, Self.lostHint], in: hintLabel)
            ),
            previewView.topAnchor.constraint(equalTo: stack.bottomAnchor),
            previewView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            previewView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            previewView.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
            previewView.heightAnchor.constraint(equalToConstant: Self.previewHeight),
        ])
        return background
    }

    private static func width(of texts: [String], in label: NSTextField) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: label.font as Any]
        return ceil(texts.map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0) + 4
    }
}

/// Shows the bottom rows of the stitched picture inside the control panel.
private final class TailPreviewView: NSView {
    private(set) var image: CGImage?
    private var scale: CGFloat = 1
    private var isLost: Bool?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TailPreviewView is created in code only")
    }

    func show(_ image: CGImage, scale: CGFloat) {
        guard self.image !== image || self.scale != scale else { return }
        self.image = image
        self.scale = scale
        needsDisplay = true
    }

    func setLost(_ isLost: Bool) {
        guard self.isLost != isLost else { return }
        self.isLost = isLost
        layer?.borderWidth = isLost ? 1.5 : 1
        let color: NSColor = isLost
            ? .systemYellow.withAlphaComponent(0.8)
            : .white.withAlphaComponent(0.14)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = color.cgColor
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = Self.imageRect(
            pixelSize: CGSize(width: image.width, height: image.height),
            scale: scale,
            in: bounds
        )
        context.interpolationQuality = .high
        context.draw(image, in: rect)
    }

    /// Fits the image's width into `bounds` without enlarging narrow captures,
    /// anchored to the bottom edge so the stitched tail stays in view.
    static func imageRect(pixelSize: CGSize, scale: CGFloat, in bounds: CGRect) -> CGRect {
        guard
            pixelSize.width > 0, pixelSize.height > 0, scale > 0,
            bounds.width > 0, bounds.height > 0
        else { return .zero }
        let pointSize = CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
        let fit = min(1, bounds.width / pointSize.width)
        let drawnSize = CGSize(width: pointSize.width * fit, height: pointSize.height * fit)
        return CGRect(
            x: (bounds.midX - drawnSize.width / 2).rounded(),
            y: bounds.minY,
            width: drawnSize.width,
            height: drawnSize.height
        )
    }
}
