import Darwin
import Foundation

/// Runs share an excluded root, but only the process holding a run's lock
/// can write, recover or discard its captures.
final class CaptureStorage {
    static let current = CaptureStorage()

    private static let runPrefix = "run-"
    private let rootDirectory: URL
    let directory: URL
    private var runLock: RunLock?
    private var interruptedDropRuns: [URL] = []

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
        interruptedDropRuns = []
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else { return }
        try excludeRootFromBackup()
        let directories = try directories(in: rootDirectory)
        let recoverLegacy = includeLegacy()
        var locks: [RunLock] = []
        var files: [URL] = []
        for run in directories {
            let currentFormat = isCurrentFormat(run)
            guard currentFormat || (recoverLegacy && UUID(uuidString: run.lastPathComponent) != nil),
                  let lock = try? RunLock(run, wait: false) else { continue }
            let contents = withExtendedLifetime(lock) { try? scanFiles(in: run) }
            guard let captures = contents else { continue }
            if currentFormat && captures.hasDrop {
                interruptedDropRuns.append(run)
            }
            guard !captures.pending.isEmpty else { continue }
            locks.append(lock)
            files.append(contentsOf: captures.pending)
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
        let marker = dropMarker(in: file.deletingLastPathComponent())
        if !FileManager.default.createFile(atPath: marker.path, contents: Data(file.lastPathComponent.utf8)) {
            Log.thumbnail.error("Could not record a completed drop")
        }
    }

    /// A normal quit also cleans up interrupted drops found at launch.
    func removeFiles() {
        if runLock != nil {
            try? FileManager.default.removeItem(at: directory)
            runLock = nil
        }
        removeInterruptedDrops()
    }

    private func removeInterruptedDrops() {
        guard !interruptedDropRuns.isEmpty,
              (try? rootDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
        let manager = FileManager.default
        for run in interruptedDropRuns {
            guard let lock = try? RunLock(run, wait: false),
                  let captures = try? captureDirectories(in: run) else { continue }
            withExtendedLifetime(lock) {
                for capture in captures {
                    let marker = dropMarker(in: capture)
                    do {
                        guard let file = droppedFile(in: try pngFiles(in: capture), markedBy: marker) else { continue }
                        try manager.removeItem(at: file)
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

    private func dropMarker(in capture: URL) -> URL {
        capture.appending(path: ".dropped")
    }

    private func droppedFile(in files: [URL], markedBy marker: URL) -> URL? {
        guard (try? marker.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let name = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        // Earlier builds left an empty marker and wrote one PNG per capture.
        if name.isEmpty && files.count == 1 { return files.first }
        return files.first { $0.lastPathComponent == name }
    }

    private func scanFiles(in run: URL) throws -> (pending: [URL], hasDrop: Bool) {
        var pending: [URL] = []
        var hasDrop = false
        for capture in try captureDirectories(in: run) {
            guard let files = try? pngFiles(in: capture) else { continue }
            let dropped = droppedFile(in: files, markedBy: dropMarker(in: capture))
            hasDrop = hasDrop || dropped != nil
            pending.append(contentsOf: files.filter { $0 != dropped })
        }
        return (pending, hasDrop)
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
