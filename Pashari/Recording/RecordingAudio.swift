import Foundation

/// What sound to record alongside the video: system audio, the microphone,
/// both, or neither. Recordings are silent by default until the user turns
/// either source on.
nonisolated struct RecordingAudio: Equatable, Sendable {
    var systemAudio: Bool
    var microphone: Bool

    static let none = RecordingAudio(systemAudio: false, microphone: false)

    var sources: Set<AudioMixer.Source> {
        var result: Set<AudioMixer.Source> = []
        if systemAudio { result.insert(.system) }
        if microphone { result.insert(.microphone) }
        return result
    }
}
