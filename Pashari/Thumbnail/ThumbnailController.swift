import AppKit

/// Shows a floating thumbnail for each new screenshot and carries out what
/// the user does with it: copy, save, annotate, drag away, or close.
final class ThumbnailController {
    /// Called when the user asks to annotate a screenshot. The thumbnail is
    /// already gone by then; the editor takes over.
    var onAnnotate: ((Screenshot) -> Void)?

    private struct Entry {
        let capture: PendingCapture
        let panel: ThumbnailPanel
        /// The display the thumbnail is on. Not an `NSScreen`: that describes
        /// the display as it was when the thumbnail appeared, and says
        /// nothing useful once the display is unplugged. The ID can be
        /// looked up among the screens there are now.
        var displayID: CGDirectDisplayID
    }

    /// Newest first.
    private var entries: [Entry] = []

    /// The captures whose Copy or Save is under way. `ObjectIdentifier`
    /// stands for one particular object, the way `===` compares them.
    private var capturesBeingDelivered: Set<ObjectIdentifier> = []

    /// The thumbnails' windows, newest first. For tests.
    var panels: [NSPanel] { entries.map(\.panel) }

    init() {
        // Sent when a display is plugged in or out, or when displays are
        // rearranged or change resolution.
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensDidChange() }
        }
    }

    /// Adds a thumbnail for `screenshot` on the screen the pointer is on.
    func show(_ screenshot: Screenshot) {
        guard let displayID = (NSScreen.underMouse ?? NSScreen.main)?.displayID else {
            Log.thumbnail.error("No screen to show the thumbnail on")
            return
        }
        show(screenshot, onDisplay: displayID)
    }

    /// Adds a thumbnail for `screenshot` on the display `displayID`.
    func show(_ screenshot: Screenshot, onDisplay displayID: CGDirectDisplayID) {
        let capture = PendingCapture(screenshot: screenshot)

        let card = ThumbnailCardView(screenshot: screenshot)
        // `[weak self]` keeps these closures from keeping the controller
        // alive; `capture` is held on purpose, it is the thing to act on.
        card.onCopy = { [weak self] in self?.copy(capture) }
        card.onSave = { [weak self] in self?.save(capture) }
        card.onAnnotate = { [weak self] in self?.annotate(capture) }
        card.onClose = { [weak self] in self?.dismiss(capture) }
        card.previewView.fileURL = { capture.readyFile?.url }
        card.previewView.onDrop = { [weak self] in self?.dismiss(capture, keepingFile: true) }

        let panel = ThumbnailPanel(contentView: card)
        entries.insert(Entry(capture: capture, panel: panel, displayID: displayID), at: 0)
        moveOffMissingDisplays()
        makeRoom(on: entries[0].displayID)

        layout()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.animator().alphaValue = 1
        Log.thumbnail.info("Thumbnail shown at \(panel.frame.debugDescription, privacy: .public)")
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
                in: Preferences.saveDirectory(),
                capturedAt: capture.screenshot.capturedAt
            )
        }
    }

    /// Hands the screenshot's PNG to `output` once it is ready, then removes
    /// the thumbnail.
    ///
    /// Right after a capture the PNG may still be encoding. Clicks on Copy
    /// or Save in that time are ignored while the first one waits, so that
    /// a double-click does not save the same screenshot twice.
    private func deliver(
        _ capture: PendingCapture,
        errorTitle: String,
        to output: @escaping (PendingCapture.File) async throws -> Void
    ) {
        // `insert` reports whether the capture was not in the set yet.
        guard capturesBeingDelivered.insert(ObjectIdentifier(capture)).inserted else { return }
        Task {
            defer { capturesBeingDelivered.remove(ObjectIdentifier(capture)) }
            do {
                try await output(try await capture.file())
                dismiss(capture)
            } catch {
                ErrorAlert.show(error, title: errorTitle)
            }
        }
    }

    private func annotate(_ capture: PendingCapture) {
        dismiss(capture)
        onAnnotate?(capture.screenshot)
    }

    /// Removes the thumbnail, and its temporary file unless `keepingFile`:
    /// after a drag and drop the receiving app may still need the file.
    private func dismiss(_ capture: PendingCapture, keepingFile: Bool = false) {
        // `===` compares identity: is this the very same object?
        guard let index = entries.firstIndex(where: { $0.capture === capture }) else { return }
        entries.remove(at: index).panel.orderOut(nil)
        if !keepingFile {
            Task { await capture.removeFile() }
        }
        layout()
    }

    // MARK: - Layout

    /// Removes the oldest thumbnails on the display that no longer fit:
    /// those that would stick out of the top of the screen, and any beyond
    /// `ThumbnailLayout.maximumCount`. Other displays keep theirs.
    private func makeRoom(on displayID: CGDirectDisplayID) {
        guard let screen = Self.screen(for: displayID) else { return }
        // `entries` is newest first, and so is this.
        let stack = entries.filter { $0.displayID == displayID }
        let fitting = ThumbnailLayout.fittingCount(
            for: stack.map(\.panel.frame.size),
            in: screen.visibleFrame
        )
        for entry in stack.dropFirst(min(fitting, ThumbnailLayout.maximumCount)) {
            dismiss(entry.capture)
        }
    }

    /// Stacks the thumbnails in the bottom-left corner of their screen,
    /// newest at the bottom.
    private func layout() {
        moveOffMissingDisplays()
        for (displayID, group) in Dictionary(grouping: entries, by: \.displayID) {
            guard let screen = Self.screen(for: displayID) else { continue }
            // `visibleFrame` leaves out the menu bar and the Dock.
            let frames = ThumbnailLayout.stackFrames(
                for: group.map(\.panel.frame.size),
                in: screen.visibleFrame
            )
            for (entry, frame) in zip(group, frames) {
                entry.panel.setFrame(frame, display: true)
            }
        }
    }

    /// Displays changed: one was plugged in or out, or one changed size.
    /// Thumbnails leave the displays that are gone, and each stack is
    /// checked against the size its screen has now.
    private func screensDidChange() {
        moveOffMissingDisplays()
        for displayID in Set(entries.map(\.displayID)) {
            makeRoom(on: displayID)
        }
        layout()
        Log.thumbnail.info("Displays changed: thumbnails laid out again")
    }

    /// Moves thumbnails off displays that are gone, unplugged say, to the
    /// screen the pointer is on. Laid out for a display that is not there,
    /// they would end up out of reach, with their screenshots in them.
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

    /// The screen showing the display `displayID`, if it is still there.
    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }
}
