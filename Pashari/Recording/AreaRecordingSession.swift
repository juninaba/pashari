import AppKit
import AVFoundation
import ScreenCaptureKit

/// The area to record: in points, with the origin at the top-left corner
/// of `screen`.
struct RecordingArea {
    let screen: NSScreen
    let rect: CGRect
}

/// Record Area, from start to end. First the user draws and adjusts a
/// frame on the live screen, starting from the area recorded last; Record
/// or Return begins recording that area, and Stop ends it.
///
/// While recording, every click, scroll and key goes to the apps
/// underneath: the frame's overlay lets them through, and the bar never
/// takes the keyboard.
final class AreaRecordingSession: RecordingSession {
    /// Called with true when recording begins, and with false when it ends.
    var onRecordingChange: ((Bool) -> Void)? {
        get { runner.onRecordingChange }
        set { runner.onRecordingChange = newValue }
    }

    /// True while recording, after the frame was chosen.
    var isRecording: Bool { runner.isRecording }

    private let storage: CaptureStorage
    private let rememberArea: @MainActor (RecordingArea) -> Void
    private var audio: RecordingAudio
    private let rememberAudio: @MainActor (RecordingAudio) -> Void
    private let microphoneAuthorizationStatus: @MainActor () -> AVAuthorizationStatus
    private let requestMicrophoneAccess: @MainActor () async -> Bool
    private let showMicrophoneDeniedAlert: @MainActor () -> Bool
    private let resolveMicrophonePermission: @MainActor () async -> MicrophonePermission.RecordingDecision
    private let controls = RecordingControlPanel()
    private lazy var runner = RecordingRunner(controls: controls)

    // While choosing.
    private var editor: RecordingFrameEditor
    private var overlays: [(panel: OverlayPanel, view: RecordingAreaView, screen: NSScreen)] = []
    private var choice: CheckedContinuation<RecordingArea?, Never>?
    private var spaceObserver: SpaceChangeObserver?
    private var isRequestingMicrophonePermission = false

    /// `remembered` is the area recorded last; the frame starts there if
    /// that display is still connected and the area still fits on it.
    /// `rememberArea` keeps the area for next time once recording begins.
    init(
        storage: CaptureStorage,
        remembered: (displayID: CGDirectDisplayID, rect: CGRect)? = Preferences.recordingArea(),
        rememberArea: @escaping @MainActor (RecordingArea) -> Void = { area in
            if let displayID = area.screen.displayID {
                Preferences.setRecordingArea(area.rect, onDisplay: displayID)
            }
        },
        audio: RecordingAudio = Preferences.recordingAudio(),
        rememberAudio: @escaping @MainActor (RecordingAudio) -> Void = {
            Preferences.setRecordingAudio($0)
        },
        microphoneAuthorizationStatus: @escaping @MainActor () -> AVAuthorizationStatus = {
            MicrophonePermission.authorizationStatus()
        },
        requestMicrophoneAccess: @escaping @MainActor () async -> Bool = {
            await AVCaptureDevice.requestAccess(for: .audio)
        },
        showMicrophoneDeniedAlert: @escaping @MainActor () -> Bool = {
            MicrophonePermission.showInstructions(cancelOverlays: false)
        },
        resolveMicrophonePermission: @escaping @MainActor () async -> MicrophonePermission.RecordingDecision = {
            await MicrophonePermission.resolveForRecording()
        }
    ) {
        self.storage = storage
        self.rememberArea = rememberArea
        self.audio = audio
        self.rememberAudio = rememberAudio
        self.microphoneAuthorizationStatus = microphoneAuthorizationStatus
        self.requestMicrophoneAccess = requestMicrophoneAccess
        self.showMicrophoneDeniedAlert = showMicrophoneDeniedAlert
        self.resolveMicrophonePermission = resolveMicrophonePermission
        let screens = NSScreen.screens
        if
            let remembered,
            let index = screens.firstIndex(where: { $0.displayID == remembered.displayID }),
            CGRect(origin: .zero, size: screens[index].frame.size).contains(remembered.rect),
            RecordingFrameEditor.isLargeEnough(remembered.rect)
        {
            editor = RecordingFrameEditor(frame: .init(screen: index, rect: remembered.rect))
        } else {
            editor = RecordingFrameEditor()
        }
    }

    /// Returns the recording, or nil when the user cancelled before
    /// recording began, or nothing was recorded.
    func run() async throws -> Recording? {
        guard let area = await choose() else { return nil }
        guard let resolvedAudio = await MicrophonePermission.resolveAudio(
            audio,
            using: resolveMicrophonePermission
        ) else {
            controls.orderOut(nil)
            return nil
        }
        rememberArea(area)
        return try await record(area, audio: resolvedAudio)
    }

    /// The hotkey again: begins recording while the frame is adjusted, and
    /// stops while recording.
    func advance() {
        if choice != nil {
            confirm()
        } else if isRecording {
            stop()
        }
    }

    func stop() {
        runner.stop()
    }

    // MARK: - Choosing the frame

    private func choose() async -> RecordingArea? {
        await withCheckedContinuation { continuation in
            choice = continuation
            showOverlays()
        }
    }

    private func showOverlays() {
        for (index, screen) in NSScreen.screens.enumerated() {
            let panel = OverlayPanel(screen: screen)
            let bounds = CGRect(origin: .zero, size: screen.frame.size)
            let view = RecordingAreaView(frame: bounds)
            view.autoresizingMask = [.width, .height]
            view.region = { [weak self] point in
                self?.editor.region(at: point, on: index) ?? .outside
            }
            view.onMouseDown = { [weak self] point in
                self?.editor.begin(at: point, on: index, in: bounds)
                self?.showFrame()
            }
            view.onMouseDragged = { [weak self] point in
                self?.editor.move(to: point)
                self?.showFrame()
            }
            view.onMouseUp = { [weak self] in
                self?.editor.end()
                self?.showFrame()
            }
            view.onRecord = { [weak self] in self?.confirm() }
            view.onCancel = { [weak self] in self?.finishChoosing(with: nil) }
            // A dialog that opens meanwhile ends the session too (see
            // `ModalPresentation`).
            panel.onCancel = view.onCancel
            panel.contentView = view
            panel.makeFirstResponder(view)
            panel.orderFrontRegardless()
            overlays.append((panel, view, screen))
        }

        controls.audio = audio
        controls.onToggleSystemAudio = { [weak self] in self?.toggleSystemAudio() }
        controls.onToggleMicrophone = { [weak self] in self?.toggleMicrophone() }
        controls.onRecord = { [weak self] in self?.confirm() }
        controls.onCancel = { [weak self] in self?.finishChoosing(with: nil) }
        showFrame()
        OverlayPanel.focus(overlays.map(\.panel))
        spaceObserver = SpaceChangeObserver { [weak self] in
            // The app on the new Space has taken the keyboard. Take it
            // back, so that Return and Escape still work.
            guard let self, choice != nil, !isRequestingMicrophonePermission else { return }
            OverlayPanel.focus(overlays.map(\.panel))
        }
        Log.selection.info("Recording area overlay shown on \(self.overlays.count) screen(s)")
    }

    private func toggleSystemAudio() {
        guard choice != nil, !isRequestingMicrophonePermission else { return }
        audio.systemAudio.toggle()
        controls.audio = audio
        rememberAudio(audio)
    }

    private func toggleMicrophone() {
        guard choice != nil, !isRequestingMicrophonePermission else { return }
        if audio.microphone {
            audio.microphone = false
            controls.audio = audio
            rememberAudio(audio)
            return
        }
        switch microphoneAuthorizationStatus() {
        case .authorized:
            audio.microphone = true
            controls.audio = audio
            rememberAudio(audio)
        case .notDetermined:
            isRequestingMicrophonePermission = true
            // Step the full-screen `.screenSaver` overlays aside so macOS's
            // permission prompt is visible and clickable.
            temporarilyHideChoosingUI()
            Task { [weak self] in
                guard let self else { return }
                let granted = await requestMicrophoneAccess()
                isRequestingMicrophonePermission = false
                guard choice != nil else { return }
                if NSApp.modalWindow != nil {
                    finishChoosing(with: nil)
                    return
                }
                if granted {
                    audio.microphone = true
                    rememberAudio(audio)
                }
                restoreChoosingUI()
            }
        case .denied, .restricted:
            isRequestingMicrophonePermission = true
            temporarilyHideChoosingUI()
            let openedSettings = showMicrophoneDeniedAlert()
            isRequestingMicrophonePermission = false
            guard choice != nil else { return }
            if openedSettings || NSApp.modalWindow != nil {
                finishChoosing(with: nil)
            } else {
                restoreChoosingUI()
            }
        @unknown default:
            break
        }
    }

    private func temporarilyHideChoosingUI() {
        overlays.forEach { $0.panel.orderOut(nil) }
        controls.orderOut(nil)
        NSCursor.arrow.set()
    }

    private func restoreChoosingUI() {
        overlays.forEach { $0.panel.orderFrontRegardless() }
        controls.audio = audio
        showFrame()
        OverlayPanel.focus(overlays.map(\.panel))
    }

    /// Draws the frame on its screen, and puts the bar next to it.
    private func showFrame() {
        for (index, overlay) in overlays.enumerated() {
            overlay.view.frameRect = editor.frame?.screen == index ? editor.frame?.rect : nil
        }
        guard let frame = editor.frame else {
            controls.orderOut(nil)
            return
        }
        let screen = overlays[frame.screen].screen
        controls.show(.adjusting(frame.rect.size))
        controls.place(nextTo: Self.onScreenRect(frame.rect, on: screen), on: screen)
    }

    private func confirm() {
        guard
            choice != nil,
            !isRequestingMicrophonePermission,
            !editor.isDragging,
            let frame = editor.frame,
            RecordingFrameEditor.isLargeEnough(frame.rect)
        else { return }
        finishChoosing(with: RecordingArea(screen: overlays[frame.screen].screen, rect: frame.rect))
    }

    private func finishChoosing(with area: RecordingArea?) {
        // A continuation must be resumed exactly once.
        guard let choice else { return }
        self.choice = nil
        Log.selection.info("Recording area \(area == nil ? "cancelled" : "chosen", privacy: .public)")

        spaceObserver?.stop()
        spaceObserver = nil
        // The overlay held the keyboard. Once it is gone, the keyboard is
        // back with the app the user was working in.
        overlays.forEach { $0.panel.orderOut(nil) }
        overlays.removeAll()
        if area == nil {
            controls.orderOut(nil)
        }
        NSCursor.arrow.set()
        choice.resume(returning: area)
    }

    // MARK: - Recording

    private func record(_ area: RecordingArea, audio: RecordingAudio) async throws -> Recording? {
        let screen = area.screen
        let overlay = OverlayPanel(screen: screen)
        // Every click and scroll goes through to the app underneath.
        overlay.ignoresMouseEvents = true
        overlay.contentView = RecordedAreaOverlayView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            area: area.rect
        )
        let anchor = (rect: Self.onScreenRect(area.rect, on: screen), screen: screen)
        return try await runner.record(
            storage: storage,
            barAnchor: anchor,
            overlay: overlay,
            makeRecorder: { [runner] url, onStart, onFailure in
                let filter = try await ScreenCapturer.recordingFilter(for: screen)
                guard !runner.hasEnded else { return nil }
                return try ScreenRecorder(
                    area: area.rect,
                    filter: filter,
                    url: url,
                    audio: audio,
                    onStart: onStart,
                    onFailure: onFailure
                )
            }
        )
    }

    /// `rect` is in points from the top-left corner of `screen`, converted to
    /// AppKit screen coordinates.
    private static func onScreenRect(_ rect: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(
            x: screen.frame.minX + rect.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
