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
        let screen: NSScreen
    }

    /// Newest first.
    private var entries: [Entry] = []

    /// Adds a thumbnail for `screenshot` on the screen the pointer is on.
    func show(_ screenshot: Screenshot) {
        guard let screen = NSScreen.underMouse ?? NSScreen.main else { return }
        let capture = PendingCapture(screenshot: screenshot)

        let card = ThumbnailCardView(screenshot: screenshot)
        // `[weak self]` keeps these closures from keeping the controller
        // alive; `capture` is held on purpose, it is the thing to act on.
        card.onCopy = { [weak self] in self?.copy(capture) }
        card.onSave = { [weak self] in self?.save(capture) }
        card.onAnnotate = { [weak self] in self?.annotate(capture) }
        card.onClose = { [weak self] in self?.dismiss(capture) }
        card.previewView.fileURL = { capture.readyFile?.url }
        card.previewView.onDrop = { [weak self] in self?.dismiss(capture) }

        let panel = ThumbnailPanel(contentView: card)
        entries.insert(Entry(capture: capture, panel: panel, screen: screen), at: 0)

        // Too many to fit: the oldest ones make room.
        while entries.count > ThumbnailLayout.maximumCount, let oldest = entries.last {
            dismiss(oldest.capture)
        }

        layout()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.animator().alphaValue = 1
    }

    // MARK: - Actions

    private func copy(_ capture: PendingCapture) {
        Task {
            do {
                let file = try await capture.file()
                Clipboard.copy(pngData: file.data)
                dismiss(capture)
            } catch {
                ErrorAlert.show(error, title: String(localized: "The screenshot could not be copied"))
            }
        }
    }

    private func save(_ capture: PendingCapture) {
        Task {
            do {
                let file = try await capture.file()
                _ = try ScreenshotWriter.write(
                    file.data,
                    in: ScreenshotWriter.defaultDirectory,
                    capturedAt: capture.screenshot.capturedAt
                )
                dismiss(capture)
            } catch {
                ErrorAlert.show(error, title: String(localized: "The screenshot could not be saved"))
            }
        }
    }

    private func annotate(_ capture: PendingCapture) {
        dismiss(capture)
        onAnnotate?(capture.screenshot)
    }

    private func dismiss(_ capture: PendingCapture) {
        // `===` compares identity: is this the very same object?
        guard let index = entries.firstIndex(where: { $0.capture === capture }) else { return }
        entries.remove(at: index).panel.orderOut(nil)
        layout()
    }

    // MARK: - Layout

    /// Stacks the thumbnails in the bottom-left corner of their screen,
    /// newest at the bottom.
    private func layout() {
        for (screen, group) in Dictionary(grouping: entries, by: \.screen) {
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
}
