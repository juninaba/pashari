import Foundation

/// Each run stores its working files in its own Application Support directory.
struct CaptureStorage {
    static let current = CaptureStorage()

    let directory: URL

    init(
        rootDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Pashari/PendingCaptures")
    ) {
        directory = rootDirectory.appending(path: UUID().uuidString)
    }

    /// Called only when this process is terminating. Interrupted runs keep
    /// their files, so starting another process cannot destroy pending work.
    func removeFiles() {
        try? FileManager.default.removeItem(at: directory)
    }
}
