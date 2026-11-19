import AppKit
import QuartzCore

/// The colours of the thumbnails. A card looks like an instant photo: on
/// cream paper, or in Dark Mode on the charcoal paper of black-frame film.
enum ThumbnailStyle {
    /// The cream paper. The editor's prints and the cards in Settings keep
    /// it in Dark Mode too.
    static let paper = CGColor(srgbRed: 251 / 255, green: 248 / 255, blue: 241 / 255, alpha: 1)
    /// The badge with the number of captures: the coral of the app icon,
    /// deep enough for its white number to read (4.5:1).
    static let badge = CGColor(srgbRed: 207 / 255, green: 70 / 255, blue: 55 / 255, alpha: 1)

    static let cornerRadius: CGFloat = 12
    static let pictureCornerRadius: CGFloat = 5

    /// The colours for a card in `appearance`: light or dark, as macOS or
    /// Settings has it (see `AppAppearance`).
    static func colors(for appearance: NSAppearance) -> Colors {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    /// What changes on a card between Light and Dark Mode. Layers take
    /// fixed colours, so a card sets these again when its appearance
    /// changes.
    struct Colors {
        let paper: CGColor
        /// The fine line around the paper.
        let edge: CGColor
        /// Behind the picture, where it does not fill its place on the card.
        let pictureBackground: CGColor
        /// The fine line around the picture.
        let pictureEdge: CGColor
        /// The button icons.
        let ink: NSColor

        /// Cream paper, with the icons in the dark blue of the app icon.
        static let light = Colors(
            paper: ThumbnailStyle.paper,
            edge: CGColor(gray: 0, alpha: 0.12),
            pictureBackground: CGColor(srgbRed: 236 / 255, green: 231 / 255, blue: 220 / 255, alpha: 1),
            pictureEdge: CGColor(gray: 0, alpha: 0.14),
            ink: NSColor(srgbRed: 47 / 255, green: 76 / 255, blue: 143 / 255, alpha: 1)
        )
        /// Charcoal paper, with the icons in a light blue of the app icon,
        /// as easy to read as the dark blue on cream (7.5:1 and 7.8:1).
        static let dark = Colors(
            paper: CGColor(srgbRed: 44 / 255, green: 42 / 255, blue: 40 / 255, alpha: 1),
            edge: CGColor(gray: 1, alpha: 0.14),
            pictureBackground: CGColor(srgbRed: 33 / 255, green: 32 / 255, blue: 31 / 255, alpha: 1),
            pictureEdge: CGColor(gray: 1, alpha: 0.1),
            ink: NSColor(srgbRed: 150 / 255, green: 190 / 255, blue: 245 / 255, alpha: 1)
        )
    }
}

/// How the thumbnails move. Everything runs as Core Animation animations,
/// which the render server plays without the app's main thread.
enum ThumbnailMotion {
    /// The user asked macOS for less motion (Reduce Motion in the
    /// Accessibility settings): cards then simply appear where they belong.
    static var isReduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// A spring that settles quickly. `bouncy` makes it overshoot a little
    /// more, for a new card popping up.
    static func spring(keyPath: String, from: Any?, to: Any?, bouncy: Bool = false) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.mass = 1
        animation.stiffness = bouncy ? 260 : 230
        animation.damping = bouncy ? 15 : 24
        animation.duration = animation.settlingDuration
        return animation
    }

    static func fade(from: Float, to: Float, duration: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return animation
    }
}

extension CALayer {
    /// Sets properties without the implicit animation a standalone layer
    /// would otherwise run for each change.
    static func withoutAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}
