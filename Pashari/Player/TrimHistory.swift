import CoreMedia

/// The parts of a recording the player has trimmed it to, for Undo and
/// Redo. Trimming only narrows what plays; the file is cut once, when the
/// player closes, or the recording is copied or saved.
struct TrimHistory {
    private var ranges: [CMTimeRange]
    private var index = 0

    /// `full` is the whole recording.
    init(full: CMTimeRange) {
        ranges = [full]
    }

    var full: CMTimeRange { ranges[0] }
    var current: CMTimeRange { ranges[index] }
    var canUndo: Bool { index > 0 }
    var canRedo: Bool { index < ranges.count - 1 }

    /// Whether the current part leaves anything out, by more than a frame.
    var isTrimmed: Bool {
        Self.differ(current.start, full.start) || Self.differ(current.end, full.end)
    }

    /// Trims to `range`, if that changes anything. Redo then has nothing
    /// left to do.
    mutating func trim(to range: CMTimeRange) {
        guard Self.differ(range.start, current.start) || Self.differ(range.end, current.end) else { return }
        ranges.removeSubrange((index + 1)...)
        ranges.append(range)
        index += 1
    }

    mutating func undo() {
        if canUndo { index -= 1 }
    }

    mutating func redo() {
        if canRedo { index += 1 }
    }

    private static func differ(_ a: CMTime, _ b: CMTime) -> Bool {
        abs((a - b).seconds) > 1.0 / 120
    }
}
