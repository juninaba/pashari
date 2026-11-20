import Foundation
import Testing

@testable import Pashari

@MainActor
struct PreferencesTests {
    @Test func theSaveFolderIsTheDesktopUntilOneIsChosen() {
        let defaults = makeDefaults()

        #expect(Preferences.saveDirectory(in: defaults).path == Preferences.desktopDirectory.path)
    }

    @Test func aChosenFolderIsRemembered() throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        Preferences.setSaveDirectory(folder, in: defaults)

        #expect(Preferences.saveDirectory(in: defaults).path == folder.path)
    }

    @Test func aFolderThatNoLongerExistsFallsBackToTheDesktop() throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        Preferences.setSaveDirectory(folder, in: defaults)

        try FileManager.default.removeItem(at: folder)

        #expect(Preferences.saveDirectory(in: defaults).path == Preferences.desktopDirectory.path)
    }

    @Test func aFileIsNotAcceptedAsTheSaveFolder() throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "not-a-folder.txt")
        try Data("x".utf8).write(to: file)

        Preferences.setSaveDirectory(file, in: defaults)

        #expect(Preferences.saveDirectory(in: defaults).path == Preferences.desktopDirectory.path)
    }

    @Test func savingWritesIntoTheChosenFolder() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        Preferences.setSaveDirectory(folder, in: defaults)
        let screenshot = Screenshot(
            image: TestImages.make(width: 20, height: 10),
            scale: 1,
            capturedAt: Date()
        )

        let url = try await ScreenshotWriter.save(
            screenshot,
            in: Preferences.saveDirectory(in: defaults)
        )

        #expect(url.deletingLastPathComponent().path == folder.path)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func capturesAreSilentUntilAShutterSoundIsChosen() {
        let defaults = makeDefaults()

        #expect(Preferences.shutterSound(in: defaults) == .off)
    }

    @Test(arguments: ShutterSound.allCases)
    func aChosenShutterSoundIsRemembered(_ sound: ShutterSound) {
        let defaults = makeDefaults()

        Preferences.setShutterSound(sound, in: defaults)

        #expect(Preferences.shutterSound(in: defaults) == sound)
    }

    @Test func theAppearanceFollowsTheSystemUntilOneIsChosen() {
        let defaults = makeDefaults()

        #expect(Preferences.appearance(in: defaults) == .system)
    }

    @Test(arguments: AppAppearance.allCases)
    func aChosenAppearanceIsRemembered(_ appearance: AppAppearance) {
        let defaults = makeDefaults()

        Preferences.setAppearance(appearance, in: defaults)

        #expect(Preferences.appearance(in: defaults) == appearance)
    }

    @Test func theAreaRecordedLastIsRemembered() throws {
        let defaults = makeDefaults()
        #expect(Preferences.recordingArea(in: defaults) == nil)

        Preferences.setRecordingArea(CGRect(x: 10, y: 20, width: 300, height: 200), onDisplay: 42, in: defaults)

        let area = try #require(Preferences.recordingArea(in: defaults))
        #expect(area.displayID == 42)
        #expect(area.rect == CGRect(x: 10, y: 20, width: 300, height: 200))
    }

    @Test func settingsShowWhatChangedWhileTheyWereClosed() {
        let system = FakeSettings()
        system.saveDirectory = URL(filePath: "/Volumes/External/Screenshots")
        system.launchAtLogin = true
        let model = SettingsModel(
            readLaunchAtLogin: { system.launchAtLogin },
            readSaveDirectory: { system.saveDirectory }
        )
        model.launchAtLoginError = "An earlier attempt failed"

        // The drive is unplugged, so saves fall back to the Desktop, and the
        // login item is turned off in System Settings.
        system.saveDirectory = Preferences.desktopDirectory
        system.launchAtLogin = false
        model.reload()

        #expect(model.saveDirectory == Preferences.desktopDirectory)
        #expect(!model.launchAtLogin)
        #expect(model.launchAtLoginError == nil)
    }

    // MARK: - Helpers

    private final class FakeSettings {
        var saveDirectory = Preferences.desktopDirectory
        var launchAtLogin = false
    }

    /// A settings store used by one test only, so nothing here touches the
    /// real settings of the app.
    private func makeDefaults() -> UserDefaults {
        let name = "pashari-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeFolder() throws -> URL {
        // Resolving symlinks makes the path comparable: on macOS the
        // temporary directory is reached through a symlink (/var to
        // /private/var).
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pashari-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
