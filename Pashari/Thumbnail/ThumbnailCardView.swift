import AppKit

/// One thumbnail: the picture on top and a row of buttons under it.
final class ThumbnailCardView: NSVisualEffectView {
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onAnnotate: (() -> Void)?
    var onClose: (() -> Void)?

    let previewView: ThumbnailPreviewView

    init(screenshot: Screenshot) {
        let previewSize = ThumbnailLayout.previewSize(for: screenshot.pointSize)
        let toolbarHeight = ThumbnailLayout.toolbarHeight

        // AppKit's y axis grows upwards: the toolbar sits at y = 0 and the
        // preview above it.
        previewView = ThumbnailPreviewView(
            frame: CGRect(origin: CGPoint(x: 0, y: toolbarHeight), size: previewSize),
            image: screenshot.image
        )
        super.init(
            frame: CGRect(
                x: 0,
                y: 0,
                width: previewSize.width,
                height: previewSize.height + toolbarHeight
            )
        )

        // Frosted, dark, translucent background, the same look the system
        // uses for its floating panels. `.active` keeps it from turning grey
        // because Pashari is not the active app.
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        addSubview(previewView)
        addSubview(makeToolbar(width: previewSize.width, height: toolbarHeight))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ThumbnailCardView is created in code only")
    }

    private func makeToolbar(width: CGFloat, height: CGFloat) -> NSView {
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

        // The card never changes size, so the buttons are simply placed side
        // by side, each taking an equal share of the width.
        let toolbar = NSView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        let buttonWidth = width / CGFloat(buttons.count)
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(
                x: CGFloat(index) * buttonWidth,
                y: 0,
                width: buttonWidth,
                height: height
            )
            toolbar.addSubview(button)
        }
        return toolbar
    }
}

/// An icon button for the thumbnail's toolbar.
final class ThumbnailButton: NSButton {
    private let handler: () -> Void

    init(symbolName: String, label: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)

        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        imagePosition = .imageOnly
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        contentTintColor = .white
        isBordered = false
        // The label appears as a tooltip and is what VoiceOver reads out.
        toolTip = label
        setAccessibilityLabel(label)

        // Target-action, pointed back at this object, which then runs the
        // closure it was given.
        target = self
        action = #selector(performAction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ThumbnailButton is created in code only")
    }

    // React to the first click even though the panel never has focus.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func performAction() {
        handler()
    }
}
