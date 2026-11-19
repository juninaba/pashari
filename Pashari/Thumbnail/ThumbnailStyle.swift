import AppKit
import QuartzCore

/// The colours of the thumbnails. A card looks like an instant photo, so
/// its paper stays light in Dark Mode too.
enum ThumbnailStyle {
    static let paper = CGColor(srgbRed: 251 / 255, green: 248 / 255, blue: 241 / 255, alpha: 1)
    /// Behind the picture, where it does not fill its place on the card.
    static let pictureBackground = CGColor(srgbRed: 236 / 255, green: 231 / 255, blue: 220 / 255, alpha: 1)
    /// The button icons, the dark blue of the app icon.
    static let ink = NSColor(srgbRed: 47 / 255, green: 76 / 255, blue: 143 / 255, alpha: 1)
    /// The badge with the number of captures: the coral of the app icon,
    /// deep enough for its white number to read (4.5:1).
    static let badge = CGColor(srgbRed: 207 / 255, green: 70 / 255, blue: 55 / 255, alpha: 1)

    static let cornerRadius: CGFloat = 12
    static let pictureCornerRadius: CGFloat = 5
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
