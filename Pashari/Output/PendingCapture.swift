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
        // Each capture gets a folder of its own, so the file inside can
        // carry the plain name it will have wherever it is dropped.
        let url = temporaryDirectory
            .appending(path: UUID().uuidString)
            .appending(path: ScreenshotWriter.fileName(capturedAt: screenshot.capturedAt))
        preparation = Task {
            let data = try await ScreenshotWriter.pngData(for: screenshot)
            try await Self.write(data, to: url)
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

    /// Deletes the temporary file, once the thumbnail is gone. If the file is
    /// still being written, this waits for that first; otherwise the file
    /// would appear after it was meant to be deleted.
    func removeFile() async {
        guard let file = try? await preparation.value else { return }
        try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
    }

    /// A full Retina screenshot is several megabytes. `@concurrent` writes
    /// it off the main thread, so the screen does not stutter meanwhile.
    @concurrent
    private static func write(_ data: Data, to url: URL) async throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    /// Where the temporary files live. Each one is deleted when its thumbnail
    /// goes, except after a drag and drop: the app it was dropped into may
    /// read it later. The whole folder is emptied when Pashari starts and
    /// quits.
    static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "Pashari")
    }

    static func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}
