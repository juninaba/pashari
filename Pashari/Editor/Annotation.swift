import CoreGraphics
import Foundation

/// One mark drawn on top of a screenshot.
///
/// All coordinates are in points of the original image, with the origin at
/// its top-left corner and y growing downwards. They do not depend on zoom
/// or on how the image is cropped.
struct Annotation: Equatable, Identifiable {
    /// What kind of mark it is, together with the geometry that kind needs.
    /// A Swift enum case can carry its own data, like a tagged union.
    enum Shape: Equatable {
        case arrow(from: CGPoint, to: CGPoint)
        case line(from: CGPoint, to: CGPoint)
        case rectangle(CGRect)
        case ellipse(CGRect)
        case pen([CGPoint])
        case highlighter([CGPoint])
        /// `origin` is the top-left corner of the text.
        case text(String, origin: CGPoint)
        case blur(CGRect)
        /// A numbered badge: 1, 2, 3...
        case counter(Int, center: CGPoint)
    }

    let id: UUID
    var shape: Shape
    var color: AnnotationColor
    var size: StrokeSize

    init(id: UUID = UUID(), shape: Shape, color: AnnotationColor, size: StrokeSize) {
        self.id = id
        self.shape = shape
        self.color = color
        self.size = size
    }
}

/// The palette offered in the editor.
enum AnnotationColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, black, white

    var id: Self { self }

    var cgColor: CGColor {
        switch self {
        case .red: CGColor(srgbRed: 0.93, green: 0.21, blue: 0.21, alpha: 1)
        case .orange: CGColor(srgbRed: 0.97, green: 0.55, blue: 0.13, alpha: 1)
        case .yellow: CGColor(srgbRed: 0.99, green: 0.83, blue: 0.16, alpha: 1)
        case .green: CGColor(srgbRed: 0.20, green: 0.70, blue: 0.35, alpha: 1)
        case .blue: CGColor(srgbRed: 0.16, green: 0.47, blue: 0.95, alpha: 1)
        case .black: CGColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1)
        case .white: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        }
    }

    /// Text placed on top of this colour (the number in a badge) uses dark
    /// ink on the light colours and white on the rest.
    var prefersDarkText: Bool {
        self == .yellow || self == .white
    }
}

/// Three sizes that scale every tool together.
enum StrokeSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: Self { self }

    /// Arrows, lines, shapes and the pen.
    var lineWidth: CGFloat {
        switch self {
        case .small: 2
        case .medium: 4
        case .large: 7
        }
    }

    var highlighterWidth: CGFloat {
        switch self {
        case .small: 12
        case .medium: 18
        case .large: 26
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .small: 14
        case .medium: 20
        case .large: 30
        }
    }

    var counterRadius: CGFloat {
        switch self {
        case .small: 10
        case .medium: 14
        case .large: 19
        }
    }
}
