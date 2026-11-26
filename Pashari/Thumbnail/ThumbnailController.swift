import AppKit

final class ThumbnailController {
    /// Called when the user asks to annotate a screenshot. The thumbnail is
    /// already gone by then; the editor takes over.
    var onAnnotate: ((Screenshot) -> Void)?

    /// Hands the working capture and its display to the pin controller.
    var onPin: ((PendingCapture, CGDirectDisplayID) -> Void)?

    /// Called when the user asks to play a recording. The thumbnail is
    /// already gone by then, but not its file: the player takes it over.
    var onPlay: ((Recording) -> Void)?

    private final class Entry {
        let capture: PendingCapture
        var card: ThumbnailCardView?
        var previewTask: Task<Void, Never>?
        /// The display the thumbnail is on. Not an `NSScreen`: that describes
        /// the display as it was when the thumbnail appeared, and says
        /// nothing useful once the display is unplugged. The ID can be
        /// looked up among the screens there are now.
        var displayID: CGDirectDisplayID

        init(capture: PendingCapture, displayID: CGDirectDisplayID) {
            self.capture = capture
            self.displayID = displayID
        }
    }

    /// Newest first.
    private var entries: [Entry] = []
    /// One window for each display with thumbnails on it.
    private var panels: [CGDirectDisplayID: ThumbnailPanel] = [:]
    let storage: CaptureStorage
    private let saveDirectory: @MainActor () -> URL
    private let showError: @MainActor (Error, String) -> Void
    private let pasteboard: NSPasteboard

    private var capturesBeingDelivered: Set<ObjectIdentifier> = []

    /// Includes captures waiting for room in the visible stack.
    var hasPendingCaptures: Bool { !entries.isEmpty }
    var pendingCount: Int { entries.count }

    /// Only visible captures have cards. Newest first; also used by tests.
    var cards: [ThumbnailCardView] { entries.compactMap(\.card) }

    init(
        storage: CaptureStorage = .current,
        saveDirectory: @escaping @MainActor () -> URL = { Preferences.saveDirectory() },
        showError: @escaping @MainActor (Error, String) -> Void = { ErrorAlert.show($0, title: $1) },
        pasteboard: NSPasteboard = .general
    ) {
        self.storage = storage
        self.saveDirectory = saveDirectory
        self.showError = showError
        self.pasteboard = pasteboard
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensDidChange() }
        }
    }

    func show(_ screenshot: Screenshot) {
        guard let displayID = (NSScreen.underMouse ?? NSScreen.main)?.displayID else {
            Log.thumbnail.error("No screen to show the thumbnail on")
            return
        }
        show(screenshot, onDisplay: displayID)
    }

    func show(_ screenshot: Screenshot, onDisplay displayID: CGDirectDisplayID) {
        show(PendingCapture(screenshot: screenshot, storage: storage), onDisplay: displayID)
    }

    /// With no screen at hand, say just after its display was unplugged,
    /// the recording waits for one, as restored captures do.
    func show(_ recording: Recording) {
        show(recording, onDisplay: (NSScreen.underMouse ?? NSScreen.main)?.displayID ?? CGMainDisplayID())
    }

    func show(_ recording: Recording, onDisplay displayID: CGDirectDisplayID) {
        show(PendingCapture(recording: recording), onDisplay: displayID)
    }

    func show(_ capture: PendingCapture, onDisplay displayID: CGDirectDisplayID) {
        entries.insert(Entry(capture: capture, displayID: displayID), at: 0)
        layout()
    }

    func restore(_ files: [URL]) throws {
        let displayID = (NSScreen.underMouse ?? NSScreen.main)?.displayID ?? CGMainDisplayID()
        var recovered: [Entry] = []
        var failure: Error?
        for file in files {
            do {
                let capture = try PendingCapture(restoring: file, storage: storage)
                recovered.append(Entry(capture: capture, displayID: displayID))
            } catch {
                failure = error
            }
        }
        entries.append(contentsOf: recovered.sorted { $0.capture.capturedAt > $1.capture.capturedAt })
        layout()
        if let failure { throw failure }
    }

    private func makeCard(for entry: Entry, on screen: NSScreen) -> ThumbnailCardView {
        let capture = entry.capture
        let card = ThumbnailCardView(imageSize: capture.pointSize, duration: capture.recording?.duration)
        card.onCopy = { [weak self] in self?.copy(capture) }
        card.onSave = { [weak self] in self?.save(capture) }
        card.onAnnotate = { [weak self] in self?.annotate(capture) }
        if capture.kind == .screenshot {
            card.onPin = { [weak self] in self?.pin(capture) }
        }
        card.onPlay = { [weak self] in self?.play(capture) }
        card.onClose = { [weak self] in self?.close(capture) }
        card.previewView.fileURL = { [weak self] in
            guard self?.capturesBeingDelivered.contains(ObjectIdentifier(capture)) == false else { return nil }
            return capture.readyFileURL
        }
        card.previewView.onDrop = { [weak self] in
            if let url = capture.readyFileURL { self?.storage.recordDelivery(of: url) }
            self?.dismiss(capture, keepingFile: true)
        }
        card.setActionsEnabled(!capturesBeingDelivered.contains(ObjectIdentifier(capture)))

        // Keep Retina detail when a display change moves this card to another screen.
        let maxPixelSize = Int(ThumbnailLayout.maximumPreviewSize.width * max(2, screen.backingScaleFactor))
        let part = ThumbnailLayout.previewedPart(of: capture.pointSize)
        let showError = self.showError
        entry.previewTask = Task { [weak card] in
            do {
                try Task.checkCancellation()
                let image = try await capture.thumbnail(of: part, maxPixelSize: maxPixelSize)
                guard !Task.isCancelled else { return }
                card?.show(image)
            } catch {
                guard !Task.isCancelled, card != nil else { return }
                showError(error, String(localized: "The screenshot could not be opened"))
            }
        }
        return card
    }

    // MARK: - Actions

    private func copy(_ capture: PendingCapture) {
        switch capture.kind {
        case .screenshot:
            deliver(capture, errorTitle: String(localized: "The screenshot could not be copied")) { capture in
                let file = try await capture.file()
                try Clipboard.copy(pngData: file.data, to: self.pasteboard)
            }
        case .recording:
            // The file itself goes on the clipboard, so it must stay until
            // it has been pasted: until Pashari quits, as after a drop.
            deliver(
                capture,
                keepingFile: true,
                errorTitle: String(localized: "The recording could not be copied")
            ) { capture in
                let url = try await capture.fileURL()
                Clipboard.copy(fileURL: url, to: self.pasteboard)
                self.storage.recordDelivery(of: url)
            }
        }
    }

    private func save(_ capture: PendingCapture) {
        switch capture.kind {
        case .screenshot:
            deliver(capture, errorTitle: String(localized: "The screenshot could not be saved")) { capture in
                let file = try await capture.file()
                _ = try await ScreenshotWriter.write(
                    file.data,
                    in: self.saveDirectory(),
                    named: file.url.lastPathComponent
                )
            }
        case .recording:
            deliver(capture, errorTitle: String(localized: "The recording could not be saved")) { capture in
                _ = try await RecordingFiles.move(try await capture.fileURL(), into: self.saveDirectory())
            }
        }
    }

    /// Right after a capture the PNG may still be encoding. Clicks on Copy
    /// or Save in that time are ignored while the first one waits, so that
    /// a double-click does not save the same screenshot twice.
    private func deliver(
        _ capture: PendingCapture,
        keepingFile: Bool = false,
        errorTitle: String,
        to output: @escaping (PendingCapture) async throws -> Void
    ) {
        guard capturesBeingDelivered.insert(ObjectIdentifier(capture)).inserted else { return }
        updateActions(for: capture)
        Task {
            defer {
                capturesBeingDelivered.remove(ObjectIdentifier(capture))
                updateActions(for: capture)
            }
            do {
                try await output(capture)
                dismiss(capture, keepingFile: keepingFile)
            } catch {
                showError(error, errorTitle)
            }
        }
    }

    private func play(_ capture: PendingCapture) {
        guard
            !capturesBeingDelivered.contains(ObjectIdentifier(capture)),
            let recording = capture.recording
        else { return }
        dismiss(capture, keepingFile: true)
        onPlay?(recording)
    }

    private func pin(_ capture: PendingCapture) {
        guard
            let onPin,
            !capturesBeingDelivered.contains(ObjectIdentifier(capture)),
            let entry = entries.first(where: { $0.capture === capture })
        else { return }
        dismiss(capture, keepingFile: true)
        onPin(capture, entry.displayID)
    }

    private func annotate(_ capture: PendingCapture) {
        guard capturesBeingDelivered.insert(ObjectIdentifier(capture)).inserted else { return }
        updateActions(for: capture)
        Task {
            defer {
                capturesBeingDelivered.remove(ObjectIdentifier(capture))
                updateActions(for: capture)
            }
            do {
                let screenshot = try await capture.screenshot()
                // The thumbnail may have been closed while its PNG was loading.
                guard entries.contains(where: { $0.capture === capture }) else { return }
                dismiss(capture)
                onAnnotate?(screenshot)
            } catch {
                guard entries.contains(where: { $0.capture === capture }) else { return }
                showError(error, String(localized: "The screenshot could not be opened"))
            }
        }
    }

    private func updateActions(for capture: PendingCapture) {
        let entry = entries.first { $0.capture === capture }
        entry?.card?.setActionsEnabled(!capturesBeingDelivered.contains(ObjectIdentifier(capture)))
    }

    private func close(_ capture: PendingCapture) {
        guard !capturesBeingDelivered.contains(ObjectIdentifier(capture)) else { return }
        dismiss(capture)
    }

    /// Removes the thumbnail, and its temporary file unless `keepingFile`:
    /// after a drag and drop the receiving app may still need the file.
    private func dismiss(_ capture: PendingCapture, keepingFile: Bool = false) {
        guard let index = entries.firstIndex(where: { $0.capture === capture }) else { return }
        let entry = entries.remove(at: index)
        if let card = entry.card {
            panels[entry.displayID]?.stackView.dismiss(card)
        }
        release(entry)
        if !keepingFile {
            Task { await capture.removeFile() }
        }
        layout()
    }

    // MARK: - Layout

    /// Lets go of the card and its preview image. The PNG stays.
    private func release(_ entry: Entry) {
        entry.previewTask?.cancel()
        entry.previewTask = nil
        entry.card = nil
    }

    /// Piles the thumbnails up in the bottom-left corner of their screen,
    /// newest in front; spread out, they stand in a column, newest at the
    /// bottom. Older captures wait off-screen until there is room in that
    /// column. Their cards and preview images are released; the PNG stays.
    private func layout() {
        moveOffMissingDisplays()
        let groups = Dictionary(grouping: entries, by: \.displayID)
        for (displayID, panel) in panels where groups[displayID] == nil {
            if let screen = Self.screen(for: displayID) {
                panel.stackView.show([], pendingCount: 0, in: screen.visibleFrame)
            } else {
                panel.close()
                panels[displayID] = nil
            }
        }
        for (displayID, group) in groups {
            guard let screen = Self.screen(for: displayID) else { continue }
            let fitting = ThumbnailLayout.fittingCount(
                for: group.map { ThumbnailLayout.cardSize(for: $0.capture.pointSize) },
                in: screen.visibleFrame
            )
            let visibleCount = min(fitting, ThumbnailLayout.maximumCount)
            let visible = group.prefix(visibleCount)
            for entry in group.dropFirst(visibleCount) {
                release(entry)
            }
            for entry in visible where entry.card == nil {
                entry.card = makeCard(for: entry, on: screen)
            }
            let panel = panels[displayID] ?? ThumbnailPanel()
            panels[displayID] = panel
            panel.stackView.show(visible.compactMap(\.card), pendingCount: group.count, in: screen.visibleFrame)
        }
    }

    private func screensDidChange() {
        layout()
        Log.thumbnail.info("Displays changed: thumbnails laid out again")
    }

    private func moveOffMissingDisplays() {
        let connected = Set(NSScreen.screens.compactMap(\.displayID))
        guard
            let fallback = (NSScreen.underMouse ?? NSScreen.main ?? NSScreen.screens.first)?.displayID
        else {
            return
        }
        for index in entries.indices where !connected.contains(entries[index].displayID) {
            entries[index].displayID = fallback
        }
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }
}
