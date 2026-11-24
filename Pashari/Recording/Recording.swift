import CoreGraphics
import Foundation

/// A finished recording of an area or a window of the screen: an MP4 file in a
/// working folder of its own (see `CaptureStorage`), as a screenshot has its PNG.
struct Recording {
    let url: URL
    /// The size of the recorded area or window, in points.
    let pointSize: CGSize
    let duration: TimeInterval
    /// When recording began.
    let capturedAt: Date
}
