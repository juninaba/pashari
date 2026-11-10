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

    /// Where a drag from `start` ends while Shift is held: arrows and lines
    /// snap to the nearest 45 degrees, rectangles and ellipses become
    /// squares and circles. Other tools are left alone. The result never
    /// leaves `bounds`.
    func constrainedEnd(from start: CGPoint, to end: CGPoint, within bounds: CGRect) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y

        switch self {
        case .arrow, .line:
            guard dx != 0 || dy != 0 else { return end }
            // The eight allowed directions, as unit vectors. Picking from a
            // table keeps "horizontal" exactly horizontal, with no rounding
            // error creeping into the other axis.
            let diagonal = CGFloat(0.5).squareRoot()
            let directions: [CGPoint] = [
                CGPoint(x: 1, y: 0), CGPoint(x: diagonal, y: diagonal),
                CGPoint(x: 0, y: 1), CGPoint(x: -diagonal, y: diagonal),
                CGPoint(x: -1, y: 0), CGPoint(x: -diagonal, y: -diagonal),
                CGPoint(x: 0, y: -1), CGPoint(x: diagonal, y: -diagonal),
            ]
            let step = Int((atan2(dy, dx) / (.pi / 4)).rounded())
            let direction = directions[((step % 8) + 8) % 8]

            // How far the pointer has gone along that direction, cut short
            // where the line would leave the image.
            var length = dx * direction.x + dy * direction.y
            if direction.x > 0 { length = min(length, (bounds.maxX - start.x) / direction.x) }
            if direction.x < 0 { length = min(length, (bounds.minX - start.x) / direction.x) }
            if direction.y > 0 { length = min(length, (bounds.maxY - start.y) / direction.y) }
            if direction.y < 0 { length = min(length, (bounds.minY - start.y) / direction.y) }
            length = max(length, 0)
            return CGPoint(x: start.x + direction.x * length, y: start.y + direction.y * length)

        case .rectangle, .ellipse:
            // The longer side of the drag sets the size, limited by the room
            // left in the direction of the drag.
            let roomX = dx < 0 ? start.x - bounds.minX : bounds.maxX - start.x
            let roomY = dy < 0 ? start.y - bounds.minY : bounds.maxY - start.y
            let side = max(min(max(abs(dx), abs(dy)), roomX, roomY), 0)
            return CGPoint(
                x: start.x + (dx < 0 ? -side : side),
                y: start.y + (dy < 0 ? -side : side)
            )

        case .select, .pen, .highlighter, .text, .counter, .blur, .crop:
            return end
        }
    }
}
