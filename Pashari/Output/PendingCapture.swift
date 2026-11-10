import Foundation

/// A screenshot that has been taken but not yet copied, saved or discarded.
/// This is what a floating thumbnail stands for.
///
/// As soon as it is created it starts encoding the PNG in the background and
/// writes it to a temporary file. Copy and Save reuse that data, and drag and
/// drop hands out the temporary file.
final class PendingCapture {
    /// The encoded image and the temporary file holding it.
    struct File: Sendable {
        let data: Data
        let url: URL
    }

    let screenshot: Screenshot

    /// The background work. `Task` is a handle to it, and `await`ing its
    /// `value` waits for the result however many times it is asked for.
    private let preparation: Task<File, Error>

    /// The file, once it is ready. Drag and drop needs the answer right away
    /// and cannot wait, so it reads this instead of awaiting `file()`.
    private(set) var readyFile: File?

    init(screenshot: Screenshot, temporaryDirectory: URL = PendingCapture.temporaryDirectory) {
        self.screenshot = screenshot
        preparation = Task {
            let data = try await ScreenshotWriter.pngData(for: screenshot)
            // Each capture gets a folder of its own, so the file inside can
            // carry the plain name it will have wherever it is dropped.
            let folder = temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: ScreenshotWriter.fileName(capturedAt: screenshot.capturedAt))
            try data.write(to: url)
            return File(data: data, url: url)
        }
        Task {
            readyFile = try? await preparation.value
        }
    }

    /// The encoded image and its temporary file, waiting for them if needed.
    func file() async throws -> File {
        try await preparation.value
    }

    // MARK: - Temporary files

    /// Where the temporary files live. Dropped files may still be read by the
    /// receiving app after the thumbnail is gone, so they are not deleted one
    /// by one; the whole folder is emptied when Pashari starts and quits.
    static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "Pashari")
    }

    static func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}
