import Foundation
import Testing

@testable import Pashari

@MainActor
struct CaptureStorageTests {
    @Test func workingFilesLiveUnderApplicationSupport() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Pashari/PendingCaptures")
        #expect(CaptureStorage.current.directory.deletingLastPathComponent().path == support.path)
    }

    @Test func startingAndCleaningAnotherSessionLeavesPendingCapturesReadable() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = CaptureStorage(rootDirectory: root)
        let capture = PendingCapture(screenshot: makeScreenshot(), storage: first)
        let original = try await capture.file()

        let second = CaptureStorage(rootDirectory: root)
        let other = PendingCapture(screenshot: makeScreenshot(), storage: second)
        let otherURL = try await other.fileURL()
        #expect(first.directory != second.directory)
        try second.withInterruptedFiles(includeLegacy: { true }) { #expect($0.isEmpty) }
        second.removeFiles()

        #expect(!FileManager.default.fileExists(atPath: otherURL.path))
        #expect(FileManager.default.fileExists(atPath: original.url.path))
        #expect(try await capture.file().data == original.data)
        #expect(try await capture.screenshot().image.width == 200)
        first.removeFiles()
        #expect(!FileManager.default.fileExists(atPath: first.directory.path))
    }

    @Test func marksTheRootExcludedBeforeCreatingAnyPNG() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = CaptureStorage(rootDirectory: root)

        let capture = try storage.makeCaptureDirectory()

        #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: capture.path).isEmpty)
    }

    @Test func anInterruptedRunCanBeClaimedAndLegacyFilesCanBeRestoredOrDiscarded() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let screenshot = makeScreenshot()
        let stopped = try await writeAndReleaseRun(screenshot, root: root)
        let legacyDirectory = root.appending(path: UUID().uuidString).appending(path: UUID().uuidString)
        let legacy = legacyDirectory.appending(path: stopped.url.lastPathComponent)
        let unrelated = legacyDirectory.appending(path: "notes.txt")
        try manager.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try stopped.data.write(to: legacy)
        try Data("keep".utf8).write(to: unrelated)

        let storage = CaptureStorage(rootDirectory: root)
        let another = CaptureStorage(rootDirectory: root)
        try storage.withInterruptedFiles(includeLegacy: { false }) { files in
            #expect(files.map(\.standardizedFileURL.path) == [stopped.url.path])
            try another.withInterruptedFiles(includeLegacy: { false }) { #expect($0.isEmpty) }
        }
        #expect(manager.fileExists(atPath: stopped.url.path))
        #expect(manager.fileExists(atPath: legacy.path))

        var recovered: PendingCapture?
        try storage.withInterruptedFiles(includeLegacy: { true }) { files in
            #expect(Set(files.map(\.standardizedFileURL.path)) == [legacy.path, stopped.url.path])
            let legacyFile = try #require(files.first { $0.standardizedFileURL.path == legacy.path })
            let interruptedFile = try #require(files.first { $0.standardizedFileURL.path == stopped.url.path })
            recovered = try PendingCapture(restoring: legacyFile, storage: storage)
            try storage.discard(interruptedFile)
        }
        let restored = try #require(recovered)
        let file = try await restored.file()
        #expect(file.url.lastPathComponent == legacy.lastPathComponent)
        #expect(file.data == stopped.data)
        #expect(restored.readyFileURL == file.url)
        #expect(restored.pointSize == screenshot.pointSize)
        #expect(!manager.fileExists(atPath: legacy.path))
        #expect(!manager.fileExists(atPath: stopped.url.path))
        #expect(manager.fileExists(atPath: unrelated.path))
        try another.withInterruptedFiles(includeLegacy: { true }) { #expect($0.isEmpty) }
        storage.removeFiles()
        #expect(!manager.fileExists(atPath: file.url.path))
    }

    @Test func aTruncatedPNGStaysAvailableToDiscardAfterRestoreFails() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let stopped = try await writeAndReleaseRun(makeScreenshot(), root: root)
        try stopped.data.dropLast(12).write(to: stopped.url)
        let storage = CaptureStorage(rootDirectory: root)

        try storage.withInterruptedFiles(includeLegacy: { false }) { files in
            let file = try #require(files.first)
            #expect(throws: CaptureError.self) { try PendingCapture(restoring: file, storage: storage) }
            #expect(manager.fileExists(atPath: file.path))
            try storage.discard(file)
        }

        #expect(!manager.fileExists(atPath: stopped.url.path))
    }

    @Test func normalQuitCleansUpDroppedFilesOnlyFromUnlockedRuns() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let screenshot = makeScreenshot()
        let live = CaptureStorage(rootDirectory: root)
        let liveDrop = try await PendingCapture(screenshot: screenshot, storage: live).fileURL()
        live.recordDelivery(of: liveDrop)

        let alreadyRunning = CaptureStorage(rootDirectory: root)
        let oldDrop: PendingCapture.File
        let olderDrop: URL
        let oldPending: URL
        do {
            let interrupted = CaptureStorage(rootDirectory: root)
            oldDrop = try await PendingCapture(screenshot: screenshot, storage: interrupted).file()
            interrupted.recordDelivery(of: oldDrop.url)
            olderDrop = try await PendingCapture(screenshot: screenshot, storage: interrupted).fileURL()
            try Data().write(to: olderDrop.deletingLastPathComponent().appending(path: ".dropped"))
            oldPending = try await PendingCapture(screenshot: screenshot, storage: interrupted).fileURL()
            try alreadyRunning.withInterruptedFiles(includeLegacy: { true }) { #expect($0.isEmpty) }
            withExtendedLifetime(interrupted) {}
        }
        let dropDirectory = oldDrop.url.deletingLastPathComponent()
        let note = dropDirectory.appending(path: "notes.txt")
        try Data("keep".utf8).write(to: note)
        let otherName = ScreenshotWriter.fileName(capturedAt: screenshot.capturedAt + 1)
        let otherPNG = dropDirectory.appending(path: otherName)
        try oldDrop.data.write(to: otherPNG)

        // This process was already running when the drop's owner was interrupted.
        alreadyRunning.removeFiles()
        #expect(try Data(contentsOf: oldDrop.url) == oldDrop.data)
        #expect(manager.fileExists(atPath: olderDrop.path))

        let next = CaptureStorage(rootDirectory: root)
        try next.withInterruptedFiles(includeLegacy: { true }) { files in
            #expect(Set(files.map(\.standardizedFileURL.path)) == [oldPending.path, otherPNG.path])
        }
        #expect(try Data(contentsOf: oldDrop.url) == oldDrop.data)

        next.removeFiles()

        #expect(!manager.fileExists(atPath: oldDrop.url.path))
        #expect(!manager.fileExists(atPath: olderDrop.path))
        #expect(manager.fileExists(atPath: oldPending.path))
        #expect(manager.fileExists(atPath: liveDrop.path))
        #expect(manager.fileExists(atPath: note.path))
        #expect(try Data(contentsOf: otherPNG) == oldDrop.data)
        live.removeFiles()
    }

    @Test func partialRecoveryDoesNotTurnAnAmbiguousOldDropIntoACleanupTarget() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let screenshot = makeScreenshot()
        let good: PendingCapture.File
        let confirmedDrop: URL
        do {
            let run = CaptureStorage(rootDirectory: root)
            good = try await PendingCapture(screenshot: screenshot, storage: run).file()
            confirmedDrop = try await PendingCapture(screenshot: screenshot, storage: run).fileURL()
            run.recordDelivery(of: confirmedDrop)
        }
        let capture = good.url.deletingLastPathComponent()
        let badName = ScreenshotWriter.fileName(capturedAt: screenshot.capturedAt + 1)
        let bad = capture.appending(path: badName)
        try good.data.dropLast(12).write(to: bad)
        try Data().write(to: capture.appending(path: ".dropped"))

        let next = CaptureStorage(rootDirectory: root)
        try next.withInterruptedFiles(includeLegacy: { true }) { files in
            let complete = try #require(files.first { $0.lastPathComponent == good.url.lastPathComponent })
            let incomplete = try #require(files.first { $0.lastPathComponent == badName })
            _ = try PendingCapture(restoring: complete, storage: next)
            #expect(throws: CaptureError.self) { try PendingCapture(restoring: incomplete, storage: next) }
        }
        next.removeFiles()

        #expect(!manager.fileExists(atPath: confirmedDrop.path))
        #expect(manager.fileExists(atPath: bad.path))
        try CaptureStorage(rootDirectory: root).withInterruptedFiles(includeLegacy: { true }) { files in
            #expect(files.map(\.standardizedFileURL.path) == [bad.path])
        }
    }

    @Test func normalQuitLeavesASymlinkedReplacementRootUntouched() async throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? manager.removeItem(at: base) }
        let root = base.appending(path: "PendingCaptures")
        let file: PendingCapture.File
        do {
            let run = CaptureStorage(rootDirectory: root)
            file = try await PendingCapture(screenshot: makeScreenshot(), storage: run).file()
            run.recordDelivery(of: file.url)
        }
        let next = CaptureStorage(rootDirectory: root)
        try next.withInterruptedFiles(includeLegacy: { true }) { #expect($0.isEmpty) }

        let replacement = base.appending(path: "other-fixture")
        try manager.copyItem(at: root, to: replacement)
        try manager.moveItem(at: root, to: base.appending(path: "original"))
        try manager.createSymbolicLink(at: root, withDestinationURL: replacement)

        next.removeFiles()

        #expect(try Data(contentsOf: file.url) == file.data)
    }

    private func writeAndReleaseRun(_ screenshot: Screenshot, root: URL) async throws -> PendingCapture.File {
        let run = CaptureStorage(rootDirectory: root)
        let file = try await PendingCapture(screenshot: screenshot, storage: run).file()
        return withExtendedLifetime(run) { file }
    }
}
