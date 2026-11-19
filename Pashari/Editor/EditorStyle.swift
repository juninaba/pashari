import AppKit
import SwiftUI

/// The editor's colours. The picture lies on the desk as a print on the
/// thumbnails' cream paper, which stays light in Dark Mode here; the desk
/// and the toolbar are light or dark as the app is (see `AppAppearance`).
enum EditorStyle {
    /// The selected tool and the Save button: the blue of the app icon,
    /// deep enough for white text on it to read (4.5:1).
    static let accent = Color(red: 28 / 255, green: 118 / 255, blue: 207 / 255)

    /// Behind the title bar and the toolbar.
    static let header = dynamic(
        light: NSColor(srgbRed: 243 / 255, green: 241 / 255, blue: 236 / 255, alpha: 1),
        dark: NSColor(srgbRed: 38 / 255, green: 38 / 255, blue: 41 / 255, alpha: 1)
    )
    /// Around the picture.
    static let desk = dynamic(
        light: NSColor(srgbRed: 229 / 255, green: 226 / 255, blue: 219 / 255, alpha: 1),
        dark: NSColor(srgbRed: 26 / 255, green: 26 / 255, blue: 29 / 255, alpha: 1)
    )
    static let deskDot = dynamic(
        light: NSColor(white: 0, alpha: 0.11),
        dark: NSColor(white: 1, alpha: 0.09)
    )

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

/// The desk under the picture: dots on a plain colour. It does not scroll
/// or zoom with the picture.
final class EditorDeskView: NSView {
    private static let spacing: CGFloat = 20

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Since macOS 14 a view may draw outside its bounds unless told not
        // to, and the area it is asked to draw can reach past them: the
        // dots would cover the toolbar.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditorDeskView is created in code only")
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        EditorStyle.desk.setFill()
        dirtyRect.fill()
        // Drawn when the pattern is used, so the dot takes the colour for
        // the view's appearance, at the display's resolution.
        let tile = NSImage(size: CGSize(width: Self.spacing, height: Self.spacing), flipped: false) { rect in
            EditorStyle.deskDot.setFill()
            NSBezierPath(ovalIn: CGRect(x: rect.midX - 1.2, y: rect.midY - 1.2, width: 2.4, height: 2.4)).fill()
            return true
        }
        NSColor(patternImage: tile).setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The picture as a print on the desk: paper around the canvas, with a
/// soft shadow. Only the editor shows the paper; Copy and Save take the
/// picture alone.
final class EditorPrintView: NSView {
    static let border: CGFloat = 12
    private static let cornerRadius: CGFloat = 10

    let canvas: AnnotationCanvasView
    private let paper = CALayer()

    init(canvas: AnnotationCanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        wantsLayer = true
        // A layer of its own, under the canvas's: AppKit leaves it alone.
        layer?.addSublayer(paper)
        CALayer.withoutAnimation {
            paper.backgroundColor = ThumbnailStyle.paper
            paper.cornerRadius = Self.cornerRadius
            paper.cornerCurve = .continuous
            paper.borderWidth = 0.5
            paper.borderColor = CGColor(gray: 0, alpha: 0.12)
            paper.shadowColor = CGColor(gray: 0, alpha: 1)
            paper.shadowOpacity = 0.3
            paper.shadowRadius = 14
            paper.shadowOffset = CGSize(width: 0, height: 6)
        }
        addSubview(canvas)
        // The canvas changes size when the picture is cropped.
        canvas.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(canvasFrameDidChange),
            name: NSView.frameDidChangeNotification,
            object: canvas
        )
        fitCanvas()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditorPrintView is created in code only")
    }

    override var isFlipped: Bool { true }

    @objc private func canvasFrameDidChange(_ notification: Notification) {
        fitCanvas()
    }

    private func fitCanvas() {
        let size = CGSize(
            width: canvas.frame.width + Self.border * 2,
            height: canvas.frame.height + Self.border * 2
        )
        if frame.size != size {
            setFrameSize(size)
        }
        let origin = CGPoint(x: Self.border, y: Self.border)
        if canvas.frame.origin != origin {
            canvas.setFrameOrigin(origin)
        }
        CALayer.withoutAnimation {
            paper.frame = bounds
            // Given the shape, Core Animation does not have to work it out
            // from the pixels, which would take an extra pass for every
            // frame while drawing on the canvas.
            paper.shadowPath = CGPath(
                roundedRect: bounds,
                cornerWidth: Self.cornerRadius,
                cornerHeight: Self.cornerRadius,
                transform: nil
            )
        }
    }
}
