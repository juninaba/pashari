import AppKit

/// What Pashari plays when it takes a screenshot: nothing, unless the user
/// picks a sound in Settings. The recording is in Resources/Sounds; the
/// README says where it comes from.
enum ShutterSound: String, CaseIterable, Identifiable {
    case off
    case filmCamera

    var id: Self { self }

    var label: String {
        switch self {
        case .off: String(localized: "None")
        case .filmCamera: String(localized: "Film camera")
        }
    }

    /// The recording in the app's bundle, or nil when off.
    var fileURL: URL? {
        let name: String? = switch self {
        case .off: nil
        case .filmCamera: "film-camera"
        }
        return name.flatMap { Bundle.main.url(forResource: $0, withExtension: "wav") }
    }

    /// Plays it on the output the Mac is using, such as headphones, without
    /// waiting for it to end. Not as a system sound effect: those go to the
    /// device set for sound effects in System Settings, which can be a muted
    /// speaker while the user listens on headphones.
    func play() {
        guard let url = fileURL, let sound = NSSound(contentsOf: url, byReference: true) else { return }
        // Captures in quick succession each play to the end, as the shutter
        // of a camera would.
        Self.playing.removeAll { !$0.isPlaying }
        Self.playing.append(sound)
        sound.play()
    }

    /// The sounds must be held on to while they play.
    private static var playing: [NSSound] = []
}
