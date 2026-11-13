import CoreGraphics

/// Everything the user has done to one screenshot in the editor. The
/// screenshot itself is never changed; this is applied on top when drawing
/// and when exporting.
struct AnnotationDocument: Equatable {
    /// In drawing order: later ones are drawn over earlier ones.
    var annotations: [Annotation] = []

    /// The part of the image to keep, in image points. nil keeps all of it.
    var cropRect: CGRect?

    var isEmpty: Bool {
        annotations.isEmpty && cropRect == nil
    }

    /// The number the next badge gets: one more than the highest so far.
    /// Counting the badges instead would hand out a number twice after one
    /// in the middle is deleted.
    var nextCounterNumber: Int {
        let numbers = annotations.compactMap { annotation -> Int? in
            if case .counter(let number, _) = annotation.shape { number } else { nil }
        }
        return (numbers.max() ?? 0) + 1
    }

    func topmostAnnotation(at point: CGPoint) -> Annotation? {
        annotations.last { $0.isHit(at: point) }
    }
}

/// Undo and redo by keeping earlier states.
struct History<State: Equatable> {
    private(set) var current: State
    private var undoStack: [State] = []
    private var redoStack: [State] = []

    init(_ initial: State) {
        current = initial
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func apply(_ state: State) {
        guard state != current else { return }
        undoStack.append(current)
        current = state
        redoStack.removeAll()
    }

    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(current)
        current = previous
    }

    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(current)
        current = next
    }
}
