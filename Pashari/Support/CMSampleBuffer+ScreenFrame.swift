import CoreMedia
import ScreenCaptureKit

nonisolated extension CMSampleBuffer {
    /// ScreenCaptureKit also delivers buffers with no new picture, for
    /// instance when nothing on screen changed.
    var hasNewScreenFrame: Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        // `.started` marks the very first frame.
        return status == .complete || status == .started
    }
}
