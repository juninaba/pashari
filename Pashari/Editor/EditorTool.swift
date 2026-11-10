import CoreGraphics
import Foundation

/// The tools in the editor's toolbar.
enum EditorTool: String, CaseIterable, Identifiable {
    /// Picks existing marks to move or delete them. Every other tool makes
    /// something new.
    case select
    case arrow, rectangle, ellipse, line, pen, highlighter, text, counter, blur, crop

    var id: Self { self }

    /// Name of the SF Symbol shown on the tool's button.
    var symbolName: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "oval"
        case .line: "line.diagonal"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .counter: "1.circle"
        case .blur: "drop"
        case .crop: "crop"
        }
    }

    var label: String {
        switch self {
        case .select: String(localized: "Select")
        case .arrow: String(localized: "Arrow")
        case .rectangle: String(localized: "Rectangle")
        case .ellipse: String(localized: "Ellipse")
        case .line: String(localized: "Line")
        case .pen: String(localized: "Pen")
        case .highlighter: String(localized: "Highlighter")
        case .text: String(localized: "Text")
        case .counter: String(localized: "Number")
        case .blur: String(localized: "Blur")
        case .crop: String(localized: "Crop")
        }
    }

    /// The shape this tool makes from a drag between two points, or nil for
    /// tools that do not work by dragging out a shape (select, pen,
    /// highlighter, text, number and crop are handled separately).
    func shape(from start: CGPoint, to end: CGPoint) -> Annotation.Shape? {
        let rect = CGRect(corner: start, oppositeCorner: end)
        switch self {
        case .arrow: return .arrow(from: start, to: end)
        case .line: return .line(from: start, to: end)
        case .rectangle: return .rectangle(rect)
        case .ellipse: return .ellipse(rect)
        case .blur: return .blur(rect)
        case .select, .pen, .highlighter, .text, .counter, .crop: return nil
        }
    }
}
