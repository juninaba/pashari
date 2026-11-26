import AppKit

final class PinnedScreenshotController: NSObject {
    var onUnpin: ((PendingCapture, CGDirectDisplayID) -> Void)?
    var onAnnotate: ((Screenshot, @escaping (Screenshot?) -> Void) -> Void)?

    private final class Pin {
        let capture: PendingCapture
        let panel: PinnedScreenshotPanel
        var displayID: CGDirectDisplayID
        var delivered = false
        var dropped = false
        var busy = false
        var previewPixelSize = 0
        var previewTask: Task<Void, Never>?

        init(capture: PendingCapture, panel: PinnedScreenshotPanel, displayID: CGDirectDisplayID) {
            self.capture = capture
            self.panel = panel
            self.displayID = displayID
        }
    }

    private let storage: CaptureStorage
    private let saveDirectory: @MainActor () -> URL
    private let showError: @MainActor (Error, String) -> Void
    private let pasteboard: NSPasteboard
    private var pins: [Pin] = []
    private var scrollCaptureArea: CGRect?

    var hasPendingCaptures: Bool { pins.contains { !$0.delivered } }
    var panels: [PinnedScreenshotPanel] { pins.map(\.panel) }

    init(
        storage: CaptureStorage,
        saveDirectory: @escaping @MainActor () -> URL = { Preferences.saveDirectory() },
        showError: @escaping @MainActor (Error, String) -> Void = { ErrorAlert.show($0, title: $1) },
        pasteboard: NSPasteboard = .general
    ) {
        self.storage = storage
        self.saveDirectory = saveDirectory
        self.showError = showError
        self.pasteboard = pasteboard
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    /// From the editor, finish writing the new PNG before taking over.
    func show(_ screenshot: Screenshot) async throws {
        let capture = PendingCapture(screenshot: screenshot, storage: storage)
        _ = try await capture.fileURL()
        guard show(capture) else {
            await capture.removeFile()
            throw CaptureError.displayNotFound
        }
    }

    /// From a thumbnail, take over the file that the capture already owns.
    @discardableResult
    func show(_ capture: PendingCapture, onDisplay preferredDisplay: CGDirectDisplayID? = nil) -> Bool {
        guard capture.kind == .screenshot else { return false }
        let screens = NSScreen.screens
        let captureScreen = capture.screenFrame.flatMap { frame in
            let anchor = CGPoint(x: frame.midX, y: frame.maxY - 0.5)
            return screens.first { $0.frame.contains(anchor) }
        }
        let screen = captureScreen ?? screens.first { $0.displayID == preferredDisplay }
            ?? NSScreen.underMouse ?? NSScreen.main ?? screens.first
        guard let screen, let displayID = screen.displayID else { return false }

        let placement = PinnedScreenshotLayout.initialPlacement(
            imageSize: capture.pointSize,
            captureFrame: captureScreen == nil ? nil : capture.screenFrame,
            visibleFrame: screen.visibleFrame,
            occupiedFrames: panels.map(\.frame)
        )
        let panel = PinnedScreenshotPanel(imageSize: capture.pointSize, placement: placement)
        let pin = Pin(capture: capture, panel: panel, displayID: displayID)
        panel.onCopy = { [weak self, weak pin] in if let pin { self?.copy(pin) } }
        panel.onSave = { [weak self, weak pin] in if let pin { self?.save(pin) } }
        panel.onAnnotate = { [weak self, weak pin] in if let pin { self?.annotate(pin) } }
        panel.onUnpin = { [weak self, weak pin] in if let pin { self?.unpin(pin) } }
        panel.fileURL = { capture.readyFileURL }
        panel.onDrop = { [weak self, weak pin] in
            guard let pin else { return }
            pin.dropped = true
            self?.markDelivered(pin)
        }
        panel.onGeometryChange = { [weak self, weak pin] in
            guard let pin else { return }
            if let id = pin.panel.screen?.displayID { pin.displayID = id }
            if self?.scrollCaptureArea != nil { self?.updateVisibility(of: pin) }
            self?.refreshPreview(pin)
        }
        pins.append(pin)
        updateVisibility(of: pin)
        refreshPreview(pin)
        return true
    }

    func showPendingPins() {
        for pin in pins where !pin.delivered && !overlapsScrollCapture(pin) {
            pin.panel.orderFrontRegardless()
        }
    }

    func showPins(avoiding scrollCaptureArea: CGRect?) {
        self.scrollCaptureArea = scrollCaptureArea
        for pin in pins { updateVisibility(of: pin) }
    }

    private func overlapsScrollCapture(_ pin: Pin) -> Bool {
        scrollCaptureArea?.intersects(pin.panel.frame) == true
    }

    private func updateVisibility(of pin: Pin) {
        if overlapsScrollCapture(pin) {
            if pin.panel.isVisible { pin.panel.orderOut(nil) }
        } else if !pin.panel.isVisible {
            pin.panel.orderFrontRegardless()
        }
    }

    private func refreshPreview(_ pin: Pin) {
        let size = pin.panel.imageFrame.size
        let pixels = max(1, Int((max(size.width, size.height) * pin.panel.backingScaleFactor).rounded(.up)))
        guard pin.previewPixelSize != pixels else { return }
        let firstPreview = pin.previewPixelSize == 0
        pin.previewPixelSize = pixels
        pin.previewTask?.cancel()
        pin.previewTask = Task { [weak self, weak pin, capture = pin.capture] in
            do {
                // Pinch and scroll send many intermediate sizes. Keep the
                // current bitmap visible while those events settle.
                if !firstPreview { try await Task.sleep(for: .milliseconds(100)) }
                try Task.checkCancellation()
                let image = try await capture.thumbnail(maxPixelSize: pixels)
                try Task.checkCancellation()
                pin?.panel.show(image)
            } catch {
                guard !Task.isCancelled, pin != nil else { return }
                self?.showError(error, String(localized: "The screenshot could not be opened"))
            }
        }
    }

    private func copy(_ pin: Pin) {
        perform(String(localized: "The screenshot could not be copied"), on: pin) {
            let file = try await pin.capture.file()
            guard Clipboard.copy(pngData: file.data, to: self.pasteboard) else {
                throw CaptureError.cannotWriteClipboard
            }
            self.markDelivered(pin)
        }
    }

    private func save(_ pin: Pin) {
        perform(String(localized: "The screenshot could not be saved"), on: pin) {
            let file = try await pin.capture.file()
            _ = try await ScreenshotWriter.write(file.data, in: self.saveDirectory(), named: file.url.lastPathComponent)
            self.markDelivered(pin)
        }
    }

    private func markDelivered(_ pin: Pin) {
        pin.delivered = true
        if let url = pin.capture.readyFileURL { storage.recordDelivery(of: url) }
    }

    private func annotate(_ pin: Pin) {
        guard let onAnnotate else { return }
        let storage = self.storage
        let onUnpin = self.onUnpin
        perform(String(localized: "The screenshot could not be opened"), on: pin) {
            let capture = pin.capture
            capture.screenFrame = pin.panel.imageFrame
            let screenshot = try await capture.screenshot()
            let displayID = pin.displayID
            let keepFile = pin.dropped
            self.remove(pin)
            onAnnotate(screenshot) { result in
                if let result {
                    let edited = PendingCapture(screenshot: result, storage: storage)
                    onUnpin?(edited, displayID)
                    if !keepFile {
                        // Keep the source recoverable until the replacement has a file.
                        Task {
                            guard (try? await edited.fileURL()) != nil else { return }
                            await capture.removeFile()
                        }
                    }
                } else if !keepFile {
                    Task { await capture.removeFile() }
                }
            }
        }
    }

    private func perform(_ errorTitle: String, on pin: Pin, action: @escaping () async throws -> Void) {
        guard !pin.busy else { return }
        pin.busy = true
        pin.panel.setActionsEnabled(false)
        Task {
            defer {
                pin.busy = false
                pin.panel.setActionsEnabled(true)
            }
            do {
                try await action()
            } catch {
                showError(error, errorTitle)
            }
        }
    }

    private func unpin(_ pin: Pin) {
        guard !pin.busy, pin.delivered || onUnpin != nil else { return }
        pin.capture.screenFrame = pin.panel.imageFrame
        remove(pin)
        if !pin.delivered {
            onUnpin?(pin.capture, pin.displayID)
        } else if !pin.dropped {
            Task { await pin.capture.removeFile() }
        }
    }

    private func remove(_ pin: Pin) {
        pin.previewTask?.cancel()
        pin.panel.close()
        pins.removeAll { $0 === pin }
    }

    @objc private func screensDidChange() {
        guard let fallback = NSScreen.underMouse ?? NSScreen.main ?? NSScreen.screens.first else { return }
        for pin in pins {
            let screen = NSScreen.screens.first { $0.displayID == pin.displayID } ?? fallback
            pin.panel.place(in: screen.visibleFrame)
            if let id = screen.displayID { pin.displayID = id }
            refreshPreview(pin)
        }
    }
}
