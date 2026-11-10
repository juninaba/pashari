import CoreGraphics
import Foundation

/// One captured image, plus what is needed to show and save it correctly.
struct Screenshot {
    /// The pixels, at the display's full (Retina) resolution.
    let image: CGImage

    /// Pixels per point. 2.0 on a Retina display, 1.0 on a standard one.
    let scale: CGFloat

    let capturedAt: Date
}
