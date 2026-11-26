import AppKit
import Carbon.HIToolbox
import Testing

@testable import Pashari

@MainActor
struct RecordingControlPanelTests {
    @Test func whileTheFrameIsAdjustedTheBarShowsItsSizeAudioTogglesCancelAndRecord() {
        let bar = RecordingControlPanel()

        bar.show(.adjusting(CGSize(width: 1280, height: 720)))

        #expect(visibleTexts(in: bar.contentView) == ["1280 × 720"])
        #expect(visibleButtons(in: bar.contentView) == [String(localized: "Cancel"), String(localized: "Record")])
        #expect(!bar.systemAudioButton.isHidden)
        #expect(!bar.microphoneButton.isHidden)
        #expect(!bar.systemAudioButton.isActive)
        #expect(!bar.microphoneButton.isActive)
    }

    @Test func audioTogglesUpdateAppearanceInvokeHandlersAndHideWhileRecording() {
        let bar = RecordingControlPanel()
        var systemToggles = 0
        var micToggles = 0
        bar.onToggleSystemAudio = { systemToggles += 1 }
        bar.onToggleMicrophone = { micToggles += 1 }

        bar.show(.adjusting(CGSize(width: 800, height: 600)))
        bar.audio = RecordingAudio(systemAudio: true, microphone: false)
        #expect(bar.systemAudioButton.isActive)
        #expect(!bar.microphoneButton.isActive)
        #expect(bar.systemAudioButton.state == .on)
        #expect(bar.microphoneButton.state == .off)

        bar.systemAudioButton.performClick(nil)
        bar.microphoneButton.performClick(nil)
        #expect(systemToggles == 1)
        #expect(micToggles == 1)

        bar.disableButtons()
        #expect(!bar.systemAudioButton.isEnabled)
        #expect(!bar.microphoneButton.isEnabled)

        bar.show(.recording(elapsed: 1, bytes: 100))
        #expect(bar.systemAudioButton.isHidden)
        #expect(bar.microphoneButton.isHidden)
    }

    @Test func whileRecordingTheBarShowsTheTimeAndSizeAndOnlyStop() {
        let bar = RecordingControlPanel()

        bar.show(.preparing)
        #expect(visibleTexts(in: bar.contentView).filter { !$0.isEmpty } == [String(localized: "Getting ready…")])

        bar.show(.recording(elapsed: 12.6, bytes: 3_400_000))
        let texts = visibleTexts(in: bar.contentView)
        #expect(texts.first == "0:12 / 5:00")
        #expect(texts.count == 2)
        #expect(visibleButtons(in: bar.contentView) == [String(localized: "Stop")])
    }

    @Test func theBarKeepsItsSizeFromGettingReadyToTheEnd() {
        let bar = RecordingControlPanel()

        bar.show(.preparing)
        let size = bar.frame.size
        bar.show(.recording(elapsed: 0, bytes: 0))
        #expect(bar.frame.size == size)
        bar.show(.recording(elapsed: 299, bytes: 987_654_321))

        #expect(bar.frame.size == size)
    }

    @Test func theBarNeverTakesTheKeyboard() {
        #expect(!RecordingControlPanel().canBecomeKey)
    }

    @Test func timesAreInMinutesAndSeconds() {
        #expect(RecordingControlPanel.time(0) == "0:00")
        #expect(RecordingControlPanel.time(12.9) == "0:12")
        #expect(RecordingControlPanel.time(299.99) == "4:59")
        #expect(RecordingControlPanel.time(300) == "5:00")
    }
}

/// These record a test window through the whole session, so they run only
/// where Pashari has the Screen Recording permission.
@MainActor
@Suite(
    .serialized,
    .enabled(if: CGPreflightScreenCaptureAccess(), "needs the Screen Recording permission"),
    .takesTurnsOnTheScreen
)
struct AreaRecordingSessionTests {
    @Test func theAreaRecordedLastIsRecordedAgainWithTwoPressesOfTheHotkey() async throws {
        let page = try await ColorPage.show(.pageBlue)
        defer { page.close() }
        _ = try await page.listedContent()
        let storage = try TestStorage()
        defer { storage.remove() }
        let displayID = try #require(page.window.screen?.displayID)
        var remembered: CGRect?
        let session = AreaRecordingSession(
            storage: storage.storage,
            remembered: (displayID, page.area),
            rememberArea: { remembered = $0.rect }
        )
        var changes: [Bool] = []
        session.onRecordingChange = { changes.append($0) }
        let run = Task { try await session.run() }

        let view = try await waitForTheFrameOverlay()
        #expect(view.frameRect == page.area)
        session.advance()
        let bar = try await waitForTheBar { if case .recording = $0 { true } else { false } }
        #expect(!bar.isKeyWindow)
        #expect(NSApp.windows.compactMap { $0 as? OverlayPanel }.allSatisfy { !$0.isKeyWindow })
        page.fill(.pageRed)
        try await Task.sleep(for: .milliseconds(500))
        session.advance()
        let recording = try #require(try await run.value)

        #expect(remembered == page.area)
        #expect(changes == [true, false])
        #expect(recording.pointSize == page.area.size)
        #expect(recording.duration > 0.4)
        #expect(recording.url.pathExtension == "mp4")
        #expect(recording.url.path.hasPrefix(storage.storage.directory.path))
        #expect(page.isShowing(.pageRed, in: try await TestVideos.image(in: recording.url, at: recording.duration - 0.05)))
        #expect(!NSApp.windows.contains { ($0 is RecordingControlPanel || $0 is OverlayPanel) && $0.isVisible })
    }

    @Test func escapeWhileTheFrameIsAdjustedCancels() async throws {
        let storage = try TestStorage()
        defer { storage.remove() }
        let session = AreaRecordingSession(storage: storage.storage, remembered: nil, rememberArea: { _ in
            Issue.record("A cancelled recording was remembered")
        })
        let run = Task { try await session.run() }

        let view = try await waitForTheFrameOverlay()
        #expect(view.frameRect == nil)
        view.keyDown(with: try #require(escape(in: view.window)))

        #expect(try await run.value == nil)
        #expect(!NSApp.windows.contains { ($0 is RecordingControlPanel || $0 is OverlayPanel) && $0.isVisible })
    }

    @Test func aDialogThatOpensWhileRecordingKeepsWhatWasRecorded() async throws {
        let page = try await ColorPage.show(.pageBlue)
        defer { page.close() }
        _ = try await page.listedContent()
        let storage = try TestStorage()
        defer { storage.remove() }
        let displayID = try #require(page.window.screen?.displayID)
        let session = AreaRecordingSession(
            storage: storage.storage,
            remembered: (displayID, page.area),
            rememberArea: { _ in }
        )
        let run = Task { try await session.run() }

        _ = try await waitForTheFrameOverlay()
        session.advance()
        _ = try await waitForTheBar { if case .recording = $0 { true } else { false } }
        try await Task.sleep(for: .milliseconds(200))
        // Before a dialog shows, `ModalPresentation` ends the overlays.
        OverlayPanel.cancelSelection()

        let recording = try #require(try await run.value)
        #expect(FileManager.default.fileExists(atPath: recording.url.path))
    }

    @Test func aDialogEndsTheRecordingWhenItOpensNotWhenItCloses() async throws {
        let page = try await ColorPage.show(.pageBlue)
        defer { page.close() }
        _ = try await page.listedContent()
        let storage = try TestStorage()
        defer { storage.remove() }
        let displayID = try #require(page.window.screen?.displayID)
        let session = AreaRecordingSession(
            storage: storage.storage,
            remembered: (displayID, page.area),
            rememberArea: { _ in }
        )
        let run = Task { try await session.run() }

        _ = try await waitForTheFrameOverlay()
        session.advance()
        _ = try await waitForTheBar { if case .recording = $0 { true } else { false } }
        try await Task.sleep(for: .milliseconds(500))
        // Before a dialog shows, `ModalPresentation` ends the overlays. The
        // dialog then keeps the main thread in its own loop until it closes.
        OverlayPanel.cancelSelection()
        usleep(1_500_000)

        let recording = try #require(try await run.value)
        #expect(recording.duration < 1.2, "\(recording.duration) s recorded")
    }

    @Test func aDialogThatOpensWhileRecordingStartsLeavesNothingRecorded() async throws {
        let page = try await ColorPage.show(.pageBlue)
        defer { page.close() }
        _ = try await page.listedContent()
        let storage = try TestStorage()
        defer { storage.remove() }
        let displayID = try #require(page.window.screen?.displayID)
        let session = AreaRecordingSession(
            storage: storage.storage,
            remembered: (displayID, page.area),
            rememberArea: { _ in }
        )
        let run = Task { try await session.run() }

        _ = try await waitForTheFrameOverlay()
        session.advance()
        // Before the first frame, while the bar says "Getting ready…".
        _ = try await waitForTheBar { $0 == .preparing }
        OverlayPanel.cancelSelection()

        // Nothing, or the frame or two that came before the dialog: the bar
        // says "Getting ready…" until the first frame has reached it.
        let recording = try await run.value
        #expect((recording?.duration ?? 0) < 0.3, "\(recording?.duration ?? 0) s recorded")
    }

    @Test func theHotkeyShowsTheFrameThenRecordsThenStops() async throws {
        let page = try await ColorPage.show(.pageBlue)
        defer { page.close() }
        _ = try await page.listedContent()
        let storage = try TestStorage()
        defer { storage.remove() }
        let thumbnails = ThumbnailController(storage: storage.storage)
        defer {
            while let card = thumbnails.cards.first { card.onClose?() }
        }
        let displayID = try #require(page.window.screen?.displayID)
        let coordinator = CaptureCoordinator(
            thumbnailController: thumbnails,
            ensurePermission: { true },
            makeRecordingSession: { storage in
                AreaRecordingSession(storage: storage, remembered: (displayID, page.area), rememberArea: { _ in })
            }
        )
        var changes: [Bool] = []
        coordinator.onRecordingChange = { changes.append($0) }

        let run = try #require(coordinator.recordArea())
        _ = try await waitForTheFrameOverlay()
        #expect(changes.isEmpty)
        coordinator.recordArea()
        _ = try await waitForTheBar { if case .recording = $0 { true } else { false } }
        #expect(changes == [true])
        // Other captures wait until the recording ends.
        #expect(coordinator.run { nil } == nil)
        try await Task.sleep(for: .milliseconds(300))
        coordinator.recordArea()
        await run.value

        #expect(changes == [true, false])
        #expect(thumbnails.pendingCount == 1)
        #expect(thumbnails.cards.first?.duration != nil)
    }
}

/// The frame on the overlay, before anything is recorded, which needs no
/// permission.
@MainActor
@Suite(.takesTurnsOnTheScreen)
struct RecordingAreaOverlayTests {
    @Test func dragsOnTheOverlayDrawMoveAndResizeTheFrameAndTheBarFollows() async throws {
        let storage = try TestStorage()
        defer { storage.remove() }
        let session = AreaRecordingSession(storage: storage.storage, remembered: nil, rememberArea: { _ in })
        let run = Task { try await session.run() }
        let view = try await waitForTheFrameOverlay()
        let window = try #require(view.window)
        func drag(from start: CGPoint, to end: CGPoint) throws {
            for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type,
                    location: view.convert(point, to: nil),
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                ))
                switch type {
                case .leftMouseDown: view.mouseDown(with: event)
                case .leftMouseDragged: view.mouseDragged(with: event)
                default: view.mouseUp(with: event)
                }
            }
        }

        try drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 300))
        #expect(view.frameRect == CGRect(x: 100, y: 100, width: 300, height: 200))
        let bar = try await waitForTheBar { $0 == .adjusting(CGSize(width: 300, height: 200)) }
        // On screen, AppKit's y grows upwards: the bar sits under the frame.
        let frameOnScreen = window.convertToScreen(view.convert(CGRect(x: 100, y: 100, width: 300, height: 200), to: nil))
        #expect(bar.frame.maxY <= frameOnScreen.minY)

        try drag(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 250, y: 230))
        #expect(view.frameRect == CGRect(x: 150, y: 130, width: 300, height: 200))

        try drag(from: CGPoint(x: 450, y: 330), to: CGPoint(x: 500, y: 400))
        #expect(view.frameRect == CGRect(x: 150, y: 130, width: 350, height: 270))
        _ = try await waitForTheBar { $0 == .adjusting(CGSize(width: 350, height: 270)) }

        view.keyDown(with: try #require(escape(in: window)))
        #expect(try await run.value == nil)
    }

    @Test func togglingAudioOnTheBarRemembersTheChoiceAndHandlesMicrophonePermission() async throws {
        let storage = try TestStorage()
        defer { storage.remove() }
        let screen = try #require(NSScreen.main)
        let displayID = try #require(screen.displayID)
        var remembered: [RecordingAudio] = []
        var requests = 0
        let session = AreaRecordingSession(
            storage: storage.storage,
            remembered: (displayID, CGRect(x: 200, y: 200, width: 400, height: 300)),
            rememberArea: { _ in },
            audio: .none,
            rememberAudio: { remembered.append($0) },
            microphoneAuthorizationStatus: { .notDetermined },
            requestMicrophoneAccess: {
                requests += 1
                // Overlays must step aside while the macOS permission prompt is up.
                #expect(!NSApp.windows.contains { $0 is OverlayPanel && $0.isVisible })
                return true
            },
            showMicrophoneDeniedAlert: { false }
        )
        let run = Task { try await session.run() }
        let view = try await waitForTheFrameOverlay()
        let bar = try await waitForTheBar { if case .adjusting = $0 { true } else { false } }

        bar.systemAudioButton.performClick(nil)
        #expect(bar.audio == RecordingAudio(systemAudio: true, microphone: false))

        bar.microphoneButton.performClick(nil)
        for _ in 0..<100 where !bar.audio.microphone {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(requests == 1)
        #expect(bar.audio == RecordingAudio(systemAudio: true, microphone: true))
        #expect(remembered == [
            RecordingAudio(systemAudio: true, microphone: false),
            RecordingAudio(systemAudio: true, microphone: true),
        ])
        // Overlays and bar come back after the permission request finishes.
        #expect(bar.isVisible)
        #expect(NSApp.windows.contains { $0 is OverlayPanel && $0.isVisible })

        view.keyDown(with: try #require(escape(in: view.window)))
        #expect(try await run.value == nil)
    }

    @Test func deniedMicrophoneToggleCanRestoreSelectionOrCancelForSystemSettings() async throws {
        let storage = try TestStorage()
        defer { storage.remove() }
        let screen = try #require(NSScreen.main)
        let displayID = try #require(screen.displayID)

        // Cancel on the denied alert restores the frame and keeps mic off.
        do {
            final class AlertDecision {
                var openSettings = false
            }
            let decision = AlertDecision()
            let session = AreaRecordingSession(
                storage: storage.storage,
                remembered: (displayID, CGRect(x: 200, y: 200, width: 400, height: 300)),
                rememberArea: { _ in },
                audio: .none,
                rememberAudio: { _ in Issue.record("Denied mic should not save") },
                microphoneAuthorizationStatus: { .denied },
                showMicrophoneDeniedAlert: {
                    #expect(!NSApp.windows.contains { $0 is OverlayPanel && $0.isVisible })
                    return decision.openSettings
                }
            )
            let run = Task { try await session.run() }
            let view = try await waitForTheFrameOverlay()
            let bar = try await waitForTheBar { if case .adjusting = $0 { true } else { false } }

            bar.microphoneButton.performClick(nil)
            #expect(!bar.audio.microphone)
            #expect(bar.isVisible)
            #expect(NSApp.windows.contains { $0 is OverlayPanel && $0.isVisible })

            // Choosing "Open System Settings" ends the selection cleanly.
            decision.openSettings = true
            bar.microphoneButton.performClick(nil)
            #expect(try await run.value == nil)
            #expect(!bar.isVisible)
            #expect(!NSApp.windows.contains { $0 is OverlayPanel && $0.isVisible })
            _ = view
        }
    }

    @Test func cancellingMicrophoneResolutionBeforeAreaRecordingHidesTheBar() async throws {
        let storage = try TestStorage()
        defer { storage.remove() }
        let screen = try #require(NSScreen.main)
        let displayID = try #require(screen.displayID)
        let session = AreaRecordingSession(
            storage: storage.storage,
            remembered: (displayID, CGRect(x: 200, y: 200, width: 400, height: 300)),
            rememberArea: { _ in Issue.record("Cancelled recording should not remember area") },
            audio: RecordingAudio(systemAudio: false, microphone: true),
            rememberAudio: { _ in },
            resolveMicrophonePermission: { .cancel }
        )
        let run = Task { try await session.run() }
        _ = try await waitForTheFrameOverlay()
        let bar = try await waitForTheBar { if case .adjusting = $0 { true } else { false } }

        session.advance()
        #expect(try await run.value == nil)
        #expect(!bar.isVisible)
        #expect(!NSApp.windows.contains { ($0 is RecordingControlPanel || $0 is OverlayPanel) && $0.isVisible })
    }
}

extension RecordingAreaOverlayTests {
    /// A click reaches the overlay through its window, which AppKit brings
    /// to the front: over the bar, at the same level, unless the bar comes
    /// back up.
    @Test func theBarStaysInFrontOfTheOverlayAfterTheFrameIsDragged() async throws {
        let storage = try TestStorage()
        defer { storage.remove() }
        let screen = try #require(NSScreen.main)
        let displayID = try #require(screen.displayID)
        let session = AreaRecordingSession(
            storage: storage.storage,
            remembered: (displayID, CGRect(x: 200, y: 200, width: 400, height: 300)),
            rememberArea: { _ in }
        )
        let run = Task { try await session.run() }
        let view = try await waitForTheFrameOverlay()
        let overlay = try #require(view.window)
        let bar = try await waitForTheBar { if case .adjusting = $0 { true } else { false } }

        let inside = view.convert(CGPoint(x: 300, y: 300), to: nil)
        // The mouse-up waits in the queue until the mouse-down is handled.
        NSApp.postEvent(try mouseEvent(.leftMouseUp, at: inside, in: overlay), atStart: false)
        overlay.sendEvent(try mouseEvent(.leftMouseDown, at: inside, in: overlay))
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(20))
        }

        let middle = CGPoint(x: bar.frame.midX, y: bar.frame.midY)
        #expect(NSWindow.windowNumber(at: middle, belowWindowWithWindowNumber: 0) == bar.windowNumber)
        view.keyDown(with: try #require(escape(in: overlay)))
        #expect(try await run.value == nil)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at location: CGPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}

/// Capture storage in a folder of its own, removed afterwards.
@MainActor
struct TestStorage {
    let root: URL
    let storage: CaptureStorage

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "PashariTests-\(UUID().uuidString)")
        storage = CaptureStorage(rootDirectory: root)
    }

    func remove() {
        storage.removeFiles()
        try? FileManager.default.removeItem(at: root)
    }
}

/// The texts of `view` and the views inside it that show.
@MainActor
private func visibleTexts(in view: NSView?) -> [String] {
    guard let view, !view.isHidden else { return [] }
    let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
    return own + view.subviews.flatMap { visibleTexts(in: $0) }
}

@MainActor
private func visibleButtons(in view: NSView?) -> [String] {
    guard let view, !view.isHidden else { return [] }
    let own = (view as? NSButton).flatMap { $0.title.isEmpty ? nil : [$0.title] } ?? []
    return own + view.subviews.flatMap { visibleButtons(in: $0) }
}

@MainActor
func waitForTheFrameOverlay() async throws -> RecordingAreaView {
    for _ in 0..<100 {
        let views = NSApp.windows.compactMap { $0 as? OverlayPanel }
            .filter(\.isVisible)
            .compactMap { $0.contentView as? RecordingAreaView }
        if let view = views.first(where: { $0.frameRect != nil }) ?? views.first {
            return view
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw CocoaError(.featureUnsupported)
}

@MainActor
func waitForTheBar(
    in state: (RecordingControlPanel.Status) -> Bool
) async throws -> RecordingControlPanel {
    for _ in 0..<150 {
        let bars = NSApp.windows.compactMap { $0 as? RecordingControlPanel }.filter(\.isVisible)
        if let bar = bars.first(where: { state($0.status) }) {
            return bar
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("The bar never got there")
    throw CocoaError(.featureUnsupported)
}

@MainActor
func escape(in window: NSWindow?) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window?.windowNumber ?? 0,
        context: nil,
        characters: "\u{1b}",
        charactersIgnoringModifiers: "\u{1b}",
        isARepeat: false,
        keyCode: UInt16(kVK_Escape)
    )
}
