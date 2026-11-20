import AppKit
import Testing

@testable import Pashari

@MainActor
struct ShutterSoundTests {
    @Test(arguments: ShutterSound.allCases.filter { $0 != .off })
    func eachSoundShipsWithTheAppAsAShortClip(_ sound: ShutterSound) throws {
        let url = try #require(sound.fileURL)
        let clip = try #require(NSSound(contentsOf: url, byReference: true))
        #expect(clip.duration > 0 && clip.duration < 1)
    }

    @Test func offHasNoRecording() {
        #expect(ShutterSound.off.fileURL == nil)
    }
}
