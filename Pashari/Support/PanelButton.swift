import AppKit

/// A push button that works on the first click, even while another app is
/// active.
final class PanelButton: NSButton {
    var handler: (() -> Void)?

    override class var cellClass: AnyClass? {
        get { Cell.self }
        set {}
    }

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

    /// Keeps an image beside the title on one line through the middle of the
    /// button. Next to a symbol smaller than the text, AppKit draws the title
    /// lower than in a button without an image, below the middle of the
    /// button, and the symbol above the middle of the title. This draws the
    /// title where a button without an image has it, and the image on the
    /// middle of the title's capitals.
    private final class Cell: NSButtonCell {
        override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
            var frame = frame
            if let titleFrame = titleFrameWithoutImage(in: controlView) {
                frame.origin.y = titleFrame.minY
            }
            return super.drawTitle(title, withFrame: frame, in: controlView)
        }

        override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
            var frame = frame
            if let titleFrame = titleFrameWithoutImage(in: controlView), let font {
                // The title's line is centred in its frame, and a symbol's
                // alignment rect runs from its baseline to its cap height.
                let capMiddle = titleFrame.midY + (font.ascender + font.descender - font.capHeight) / 2
                let middleFromTop = (image.size.height - image.alignmentRect.midY) / image.size.height
                frame.origin.y = capMiddle - frame.height * middleFromTop
                frame.origin.y = controlView.backingAlignedRect(frame, options: .alignAllEdgesNearest).minY
            }
            super.drawImage(image, withFrame: frame, in: controlView)
        }

        /// Where the title goes in the button without its image, or nil
        /// unless the button has both.
        private func titleFrameWithoutImage(in controlView: NSView) -> NSRect? {
            guard image != nil, !title.isEmpty, let plain = copy() as? NSButtonCell else { return nil }
            plain.image = nil
            return plain.titleRect(forBounds: controlView.bounds)
        }
    }
}
