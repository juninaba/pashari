import AppKit

final class ThumbnailController {
    /// Called when the user asks to annotate a screenshot. The thumbnail is
    /// already gone by then; the editor takes over.
    var onAnnotate: ((Screenshot) -> Void)?

    private final class Entry {
        let capture: PendingCapture
        var panel: ThumbnailPanel?
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
    private let storageDirectory: URL
    private let saveDirectory: @MainActor () -> URL
    private let showError: @MainActor (Error, String) -> Void

    private var capturesBeingDelivered: Set<ObjectIdentifier> = []

    /// Includes captures waiting for room in the visible stack.
    var hasPendingCaptures: Bool { !entries.isEmpty }
    var pendingCount: Int { entries.count }

    /// Only visible captures have windows. Newest first; also used by tests.
    var panels: [NSPanel] { entries.compactMap(\.panel) }

    init(
        storageDirectory: URL = CaptureStorage.current.directory,
        saveDirectory: @escaping @MainActor () -> URL = { Preferences.saveDirectory() },
        showError: @escaping @MainActor (Error, String) -> Void = { ErrorAlert.show($0, title: $1) }
    ) {
        self.storageDirectory = storageDirectory
        self.saveDirectory = saveDirectory
        self.showError = showError
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
        let capture = PendingCapture(screenshot: screenshot, directory: storageDirectory)
        entries.insert(Entry(capture: capture, displayID: displayID), at: 0)
        layout()
    }

    private func makePanel(for entry: Entry, on screen: NSScreen) -> ThumbnailPanel {
        let capture = entry.capture
        let card = ThumbnailCardView(imageSize: capture.pointSize)
        card.onCopy = { [weak self] in self?.copy(capture) }
        card.onSave = { [weak self] in self?.save(capture) }
        card.onAnnotate = { [weak self] in self?.annotate(capture) }
        card.onClose = { [weak self] in self?.close(capture) }
        card.previewView.fileURL = { [weak self] in
            guard self?.capturesBeingDelivered.contains(ObjectIdentifier(capture)) == false else { return nil }
            return capture.readyFileURL
        }
        card.previewView.onDrop = { [weak self] in self?.dismiss(capture, keepingFile: true) }
        card.setActionsEnabled(!capturesBeingDelivered.contains(ObjectIdentifier(capture)))

        let panel = ThumbnailPanel(contentView: card)
        panel.alphaValue = 0
        // Keep Retina detail when a display change moves this card to another screen.
        let maxPixelSize = Int(ThumbnailLayout.maximumPreviewSize.width * max(2, screen.backingScaleFactor))
        let showError = self.showError
        entry.previewTask = Task { [weak card] in
            do {
                try Task.checkCancellation()
                let image = try await capture.thumbnail(maxPixelSize: maxPixelSize)
                guard !Task.isCancelled else { return }
                card?.previewView.show(image)
            } catch {
                guard !Task.isCancelled, card != nil else { return }
                showError(error, String(localized: "The screenshot could not be opened"))
            }
        }
        return panel
    }

    // MARK: - Actions

    private func copy(_ capture: PendingCapture) {
        deliver(capture, errorTitle: String(localized: "The screenshot could not be copied")) { file in
            Clipboard.copy(pngData: file.data)
        }
    }

    private func save(_ capture: PendingCapture) {
        deliver(capture, errorTitle: String(localized: "The screenshot could not be saved")) { file in
            _ = try await ScreenshotWriter.write(
                file.data,
                in: self.saveDirectory(),
                capturedAt: capture.capturedAt
            )
        }
    }

    /// Right after a capture the PNG may still be encoding. Clicks on Copy
    /// or Save in that time are ignored while the first one waits, so that
    /// a double-click does not save the same screenshot twice.
    private func deliver(
        _ capture: PendingCapture,
        errorTitle: String,
        to output: @escaping (PendingCapture.File) async throws -> Void
    ) {
        guard capturesBeingDelivered.insert(ObjectIdentifier(capture)).inserted else { return }
        updateActions(for: capture)
        Task {
            defer {
                capturesBeingDelivered.remove(ObjectIdentifier(capture))
                updateActions(for: capture)
            }
            do {
                try await output(try await capture.file())
                dismiss(capture)
            } catch {
                showError(error, errorTitle)
            }
        }
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
        let card = entry?.panel?.contentView as? ThumbnailCardView
        card?.setActionsEnabled(!capturesBeingDelivered.contains(ObjectIdentifier(capture)))
    }

    private func close(_ capture: PendingCapture) {
        guard !capturesBeingDelivered.contains(ObjectIdentifier(capture)) else { return }
        dismiss(capture)
    }

    /// Removes the thumbnail, and its temporary file unless `keepingFile`:
    /// after a drag and drop the receiving app may still need the file.
    private func dismiss(_ capture: PendingCapture, keepingFile: Bool = false) {
        guard let index = entries.firstIndex(where: { $0.capture === capture }) else { return }
        hide(entries.remove(at: index))
        if !keepingFile {
            Task { await capture.removeFile() }
        }
        layout()
    }

    // MARK: - Layout

    private func hide(_ entry: Entry) {
        entry.previewTask?.cancel()
        entry.previewTask = nil
        entry.panel?.contentView = nil
        entry.panel?.close()
        entry.panel = nil
    }

    /// Stacks the thumbnails in the bottom-left corner of their screen,
    /// newest at the bottom. Older captures wait off-screen until there is
    /// room. Their panels and preview images are released; the PNG stays.
    private func layout() {
        moveOffMissingDisplays()
        for (displayID, group) in Dictionary(grouping: entries, by: \.displayID) {
            guard let screen = Self.screen(for: displayID) else { continue }
            let fitting = ThumbnailLayout.fittingCount(
                for: group.map { ThumbnailLayout.cardSize(for: $0.capture.pointSize) },
                in: screen.visibleFrame
            )
            let visibleCount = min(fitting, ThumbnailLayout.maximumCount)
            let visible = group.prefix(visibleCount)
            for entry in group.dropFirst(visibleCount) {
                hide(entry)
            }
            let frames = ThumbnailLayout.stackFrames(
                for: visible.map { ThumbnailLayout.cardSize(for: $0.capture.pointSize) },
                in: screen.visibleFrame
            )
            for (entry, frame) in zip(visible, frames) {
                if let panel = entry.panel {
                    panel.setFrame(frame, display: true)
                } else {
                    let panel = makePanel(for: entry, on: screen)
                    entry.panel = panel
                    panel.setFrame(frame, display: true)
                    panel.orderFrontRegardless()
                    panel.animator().alphaValue = 1
                }
            }
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
