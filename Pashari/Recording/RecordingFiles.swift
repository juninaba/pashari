import Foundation

enum RecordingFiles {
    /// Moves a recording into `directory`, under the same name, or with
    /// "-2", "-3"... when the name is taken. A recording can be hundreds of
    /// MB: moving it is instant on the same disk, and `@concurrent` keeps
    /// the copy to another disk off the main thread.
    @concurrent
    static func move(_ url: URL, into directory: URL) async throws -> URL {
        let destination = ScreenshotWriter.availableURL(in: directory, named: url.lastPathComponent)
        do {
            // Fails rather than replace a file that took the name meanwhile.
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            throw CaptureError.cannotSaveRecording(destination)
        }
        return destination
    }
}
