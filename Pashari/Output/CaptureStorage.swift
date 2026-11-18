import Darwin
import Foundation

/// Runs share an excluded root, but only the process holding a run's lock
/// can write, recover or discard its captures.
final class CaptureStorage {
    static let current = CaptureStorage()

    private static let runPrefix = "run-"
    private static let dropMarker = ".dropped"
    private let rootDirectory: URL
    let directory: URL
    private var runLock: RunLock?

    init(
        rootDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Pashari/PendingCaptures")
    ) {
        self.rootDirectory = rootDirectory
        directory = rootDirectory.appending(path: Self.runPrefix + UUID().uuidString)
    }

    func makeCaptureDirectory() throws -> URL {
        let manager = FileManager.default
        if runLock == nil {
            try manager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            try excludeRootFromBackup()
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            // A scanner may briefly lock the empty directory before we do.
            runLock = try RunLock(directory, wait: true)
        }
        let capture = directory.appending(path: UUID().uuidString)
        try manager.createDirectory(at: capture, withIntermediateDirectories: false)
        return capture
    }

    /// Holds the locks through the user's choice and the resulting file operations.
    func withInterruptedFiles(
        includeLegacy: () -> Bool,
        _ handle: ([URL]) throws -> Void
    ) throws {
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else { return }
        try excludeRootFromBackup()
        let directories = try directories(in: rootDirectory)
        let recoverLegacy = includeLegacy()
        var locks: [RunLock] = []
        var files: [URL] = []
        for run in directories {
            guard isCurrentFormat(run) || (recoverLegacy && UUID(uuidString: run.lastPathComponent) != nil),
                  let lock = try? RunLock(run, wait: false),
                  let pending = try? pendingFiles(in: run), !pending.isEmpty else { continue }
            locks.append(lock)
            files.append(contentsOf: pending)
        }
        try withExtendedLifetime(locks) { try handle(files) }
    }

    func restore(_ file: URL) throws -> URL {
        let destination = try makeCaptureDirectory().appending(path: file.lastPathComponent)
        try FileManager.default.moveItem(at: file, to: destination)
        removeEmptyCaptureDirectory(file.deletingLastPathComponent())
        return destination
    }

    func discard(_ file: URL) throws {
        try FileManager.default.removeItem(at: file)
        removeEmptyCaptureDirectory(file.deletingLastPathComponent())
    }

    /// A drop receiver may still be using the original URL after we exit.
    func recordDrop(of file: URL) {
        let marker = file.deletingLastPathComponent().appending(path: Self.dropMarker)
        if !FileManager.default.createFile(atPath: marker.path, contents: nil) {
            Log.thumbnail.error("Could not record a completed drop")
        }
    }

    /// A normal quit also ends the lifetime of drop URLs from interrupted runs.
    func removeFiles() {
        if runLock != nil {
            try? FileManager.default.removeItem(at: directory)
            runLock = nil
        }
        removeInterruptedDrops()
    }

    private func removeInterruptedDrops() {
        guard (try? rootDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let runs = try? directories(in: rootDirectory) else { return }
        let manager = FileManager.default
        for run in runs where isCurrentFormat(run) {
            guard let lock = try? RunLock(run, wait: false),
                  let captures = try? captureDirectories(in: run) else { continue }
            withExtendedLifetime(lock) {
                for capture in captures {
                    guard let marker = recordedDrop(in: capture) else { continue }
                    do {
                        for file in try pngFiles(in: capture) {
                            try manager.removeItem(at: file)
                        }
                        try manager.removeItem(at: marker)
                        removeEmptyCaptureDirectory(capture)
                    } catch {
                        Log.thumbnail.error("Could not clean up a completed drop")
                    }
                }
            }
        }
    }

    private func isCurrentFormat(_ directory: URL) -> Bool {
        let name = directory.lastPathComponent
        return name.hasPrefix(Self.runPrefix)
            && UUID(uuidString: String(name.dropFirst(Self.runPrefix.count))) != nil
    }

    private func excludeRootFromBackup() throws {
        var root = rootDirectory
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }

    private func directories(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func captureDirectories(in run: URL) throws -> [URL] {
        try directories(in: run).filter { UUID(uuidString: $0.lastPathComponent) != nil }
    }

    private func recordedDrop(in capture: URL) -> URL? {
        let marker = capture.appending(path: Self.dropMarker)
        return (try? marker.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true ? marker : nil
    }

    private func pendingFiles(in run: URL) throws -> [URL] {
        try captureDirectories(in: run).filter { recordedDrop(in: $0) == nil }.flatMap {
            (try? pngFiles(in: $0)) ?? []
        }
    }

    private func pngFiles(in capture: URL) throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(
            at: capture, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )
        return files.filter { file in
            file.lastPathComponent.wholeMatch(of: /pashari-[0-9]{8}-[a-z]{4}\.png/) != nil
                && (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private func removeEmptyCaptureDirectory(_ capture: URL) {
        _ = rmdir(capture.path)
        _ = rmdir(capture.deletingLastPathComponent().path)
    }
}

private final class RunLock {
    private let descriptor: Int32

    init(_ directory: URL, wait: Bool) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(descriptor, wait ? LOCK_EX : LOCK_EX | LOCK_NB) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            close(descriptor)
            throw error
        }
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }
}
