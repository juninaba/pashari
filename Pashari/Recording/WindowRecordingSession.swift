import AppKit
import ScreenCaptureKit

/// Record Window, from start to end. First the user picks a window on screen;
/// clicking it begins recording that window on its own, without whatever is in
/// front of or behind it, and Stop ends it.
///
/// While recording, every click, scroll and key goes to the apps as usual:
/// there is no overlay over the screen, and the bar never takes the keyboard.
final class WindowRecordingSession: RecordingSession {
    /// Called with true when recording begins, and with false when it ends.
    var onRecordingChange: ((Bool) -> Void)? {
        get { runner.onRecordingChange }
        set { runner.onRecordingChange = newValue }
    }

    /// True while the chosen window is being recorded, not while picking it.
    var isRecording: Bool { runner.isRecording }

    private let storage: CaptureStorage
    private let chooseWindow: @MainActor () async throws -> SCWindow?
    private let windowExists: @MainActor (CGWindowID) -> Bool
    private let audio: @MainActor () -> RecordingAudio
    private let resolveMicrophonePermission: @MainActor () async -> MicrophonePermission.RecordingDecision
    private let runner = RecordingRunner()

    init(
        storage: CaptureStorage,
        chooseWindow: @escaping @MainActor () async throws -> SCWindow? = {
            let windows = try await ScreenCapturer.selectableWindows()
            return await WindowSelectionSession(cursor: .videoCamera).run(with: windows)
        },
        windowExists: @escaping @MainActor (CGWindowID) -> Bool = {
            ScreenCapturer.windowExists($0)
        },
        audio: @escaping @MainActor () -> RecordingAudio = {
            Preferences.recordingAudio()
        },
        resolveMicrophonePermission: @escaping @MainActor () async -> MicrophonePermission.RecordingDecision = {
            await MicrophonePermission.resolveForRecording()
        }
    ) {
        self.storage = storage
        self.chooseWindow = chooseWindow
        self.windowExists = windowExists
        self.audio = audio
        self.resolveMicrophonePermission = resolveMicrophonePermission
    }

    /// Returns the recording, or nil when the user cancelled before picking a
    /// window, or nothing was recorded.
    func run() async throws -> Recording? {
        guard let window = try await chooseWindow() else { return nil }
        guard let resolvedAudio = await MicrophonePermission.resolveAudio(
            audio(),
            using: resolveMicrophonePermission
        ) else { return nil }
        return try await record(window, audio: resolvedAudio)
    }

    /// The hotkey again: stops once recording has begun.
    func advance() {
        if isRecording {
            stop()
        }
    }

    func stop() {
        runner.stop()
    }

    private func record(_ window: SCWindow, audio: RecordingAudio) async throws -> Recording? {
        let windowID = window.windowID
        let windowFrame = ScreenGeometry.flipped(
            window.frame,
            primaryScreenHeight: ScreenGeometry.primaryScreenHeight
        )
        let barAnchor = Self.screen(for: windowFrame).map { (rect: windowFrame, screen: $0) }
        // Pashari's own windows kept alive after closing (such as Settings)
        // stay on the window server with the same ID, so watch `willClose`.
        let closeObserver = NSApp.windows
            .first { $0.windowNumber > 0 && $0.windowNumber == Int(windowID) }
            .map { ownWindow in
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: ownWindow,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        Log.capture.info("Recorded window closed")
                        self?.runner.stop()
                    }
                }
            }
        defer {
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
            }
        }
        return try await runner.record(
            storage: storage,
            barAnchor: barAnchor,
            shouldEnd: { [windowExists] in
                guard !windowExists(windowID) else { return false }
                Log.capture.info("Recorded window closed")
                return true
            },
            makeRecorder: { url, onStart, onFailure in
                try ScreenRecorder(window: window, url: url, audio: audio, onStart: onStart, onFailure: onFailure)
            }
        )
    }

    /// The display holding the largest part of `rect`, or the current screen
    /// when `rect` does not intersect any display.
    static func screen(for rect: CGRect, in screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        let overlapping = screens.compactMap { screen -> (NSScreen, CGFloat)? in
            let overlap = screen.frame.intersection(rect)
            guard !overlap.isNull, !overlap.isEmpty else { return nil }
            return (screen, overlap.width * overlap.height)
        }
        return overlapping.max(by: { $0.1 < $1.1 })?.0 ?? NSScreen.underMouse ?? NSScreen.main ?? screens.first
    }
}
