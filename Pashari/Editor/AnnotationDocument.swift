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

    /// The number the next badge gets: one more than the badges so far.
    var nextCounterNumber: Int {
        let counters = annotations.filter {
            if case .counter = $0.shape { true } else { false }
        }
        return counters.count + 1
    }
}

/// Undo and redo by keeping earlier states.
///
/// The state is a value type (a struct), so every assignment is a full,
/// independent copy. Going back is just a matter of putting an old copy
/// back; nothing has to be "un-done" step by step.
struct History<State: Equatable> {
    private(set) var current: State
    private var undoStack: [State] = []
    private var redoStack: [State] = []

    init(_ initial: State) {
        current = initial
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Makes `state` the current one, remembering the old one for undo.
    /// A new change discards whatever could have been redone.
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
