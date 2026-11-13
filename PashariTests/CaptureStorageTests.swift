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
        let capture = PendingCapture(screenshot: makeScreenshot(), directory: first.directory)
        let original = try await capture.file()

        let second = CaptureStorage(rootDirectory: root)
        let other = PendingCapture(screenshot: makeScreenshot(), directory: second.directory)
        let otherURL = try await other.fileURL()
        #expect(first.directory != second.directory)
        second.removeFiles()

        #expect(!FileManager.default.fileExists(atPath: otherURL.path))
        #expect(FileManager.default.fileExists(atPath: original.url.path))
        #expect(try await capture.file().data == original.data)
        #expect(try await capture.screenshot().image.width == 200)
        first.removeFiles()
        #expect(!FileManager.default.fileExists(atPath: first.directory.path))
    }
}
