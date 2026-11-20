import AVKit
import AppKit
import SwiftUI

/// Plays a recording, dressed like the editor: the video lies as a print on
/// the dotted desk. The toolbar trims it with the yellow handles QuickTime
/// Player has, undoes and redoes trims, and copies or saves it.
///
/// Like the editor, Copy and Save close the window. Closed otherwise, the
/// recording goes back to the thumbnails, cut to what was trimmed. Until
/// then, a trim only narrows what plays, so that Undo can widen it again.
final class RecordingPlayerWindowController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    /// Called once when the window closes. The argument is the recording
    /// when it still needs a home (the window was simply closed), or nil
    /// when it was copied or saved.
    var onClose: ((Recording?) -> Void)?

    let window: Window
    let model = RecordingPlayerModel()
    let playerView = AVPlayerView()
    private(set) var recording: Recording
    private var history: TrimHistory
    private var result: Recording?
    private let storage: CaptureStorage
    private let saveDirectory: @MainActor () -> URL
    private let pasteboard: NSPasteboard
    private let showError: @MainActor (Error, String) -> Void
    private var statusObservation: NSKeyValueObservation?

    private static let minimumContentWidth: CGFloat = 560
    private static let minimumVideoHeight: CGFloat = 240

    init(
        recording: Recording,
        storage: CaptureStorage,
        saveDirectory: @escaping @MainActor () -> URL = { Preferences.saveDirectory() },
        pasteboard: NSPasteboard = .general,
        showError: @escaping @MainActor (Error, String) -> Void = { ErrorAlert.show($0, title: $1) }
    ) {
        self.recording = recording
        self.storage = storage
        self.saveDirectory = saveDirectory
        self.pasteboard = pasteboard
        self.showError = showError
        history = TrimHistory(full: Self.wholeRange(of: recording))
        let screen = NSScreen.underMouse ?? NSScreen.main
        window = Window(
            contentRect: CGRect(
                origin: .zero,
                size: Self.initialContentSize(
                    for: recording.pointSize,
                    screenSize: screen?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
                )
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = String(localized: "Play Recording")
        // As in the editor, the title bar takes the toolbar's colour. The
        // title still names the window in the Window menu.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = EditorStyle.header
        window.isReleasedWhenClosed = false
        window.contentMinSize = CGSize(
            width: Self.minimumContentWidth,
            height: Self.minimumVideoHeight + EditorToolbarView.height
        )
        window.delegate = self
        window.contentView = makeContentView()
        attachPlayer()
        if let screen {
            window.center(on: screen)
        } else {
            window.center()
        }
    }

    func show() {
        // A menu bar app is not the active app, so its window would open
        // behind everything else without this.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Space plays and pauses.
        window.makeFirstResponder(playerView)
    }

    // MARK: - Trimming

    private func trim() {
        guard !model.isBusy, playerView.canBeginTrimming else { return }
        model.isBusy = true
        playerView.beginTrimming { [weak self] result in
            MainActor.assumeIsolated { self?.didTrim(result) }
        }
    }

    private func didTrim(_ result: AVPlayerViewTrimResult) {
        model.isBusy = false
        guard result == .okButton, let item = playerView.player?.currentItem else { return updateModel() }
        let start = item.reversePlaybackEndTime.isNumeric ? item.reversePlaybackEndTime : history.full.start
        let end = item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime : history.full.end
        trim(to: CMTimeRange(start: start, end: end))
    }

    /// Keeps `range` of the recording: where the trim handles were left
    /// (tests come here directly).
    func trim(to range: CMTimeRange) {
        history.trim(to: range)
        showTrim()
    }

    @objc func undo(_ sender: Any?) {
        guard !model.isBusy, history.canUndo else { return }
        history.undo()
        showTrim()
    }

    @objc func redo(_ sender: Any?) {
        guard !model.isBusy, history.canRedo else { return }
        history.redo()
        showTrim()
    }

    /// Plays only the part trimmed to, from its start.
    private func showTrim() {
        guard let player = playerView.player, let item = player.currentItem else { return }
        let range = history.current
        item.reversePlaybackEndTime = range.start
        item.forwardPlaybackEndTime = range.end
        player.seek(to: range.start, toleranceBefore: .zero, toleranceAfter: .zero)
        updateModel()
    }

    private func updateModel() {
        model.canTrim = playerView.canBeginTrimming
        model.canUndo = history.canUndo
        model.canRedo = history.canRedo
    }

    private func attachPlayer() {
        let player = AVPlayer(url: recording.url)
        // Without the AirPlay button: the window plays, trims, and that is all.
        player.allowsExternalPlayback = false
        playerView.player = player
        // Trimming can begin once the video is ready to play.
        statusObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateModel() }
        }
    }

    private func detachPlayer() {
        playerView.player?.pause()
        statusObservation = nil
        playerView.player = nil
    }

    // MARK: - Copy and Save

    // `@objc(copy:)` is the name the menu asks for. The Swift name is
    // different because every NSObject already has a `copy()` method.
    @objc(copy:) func copyRecording(_ sender: Any?) {
        deliver(errorTitle: String(localized: "The recording could not be copied")) { [self] in
            let recording = try await trimmedRecording()
            Clipboard.copy(fileURL: recording.url, to: pasteboard)
            // On the clipboard, the file must stay until it is pasted:
            // until Pashari quits, as after a drop.
            storage.recordDrop(of: recording.url)
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        deliver(errorTitle: String(localized: "The recording could not be saved")) { [self] in
            let folder = recording.url.deletingLastPathComponent()
            if history.isTrimmed {
                // Cut straight into the folder: should that fail, the
                // recording and its trims stay as they are.
                try await RecordingFiles.trim(recording.url, to: history.current, into: saveDirectory())
            } else {
                _ = try await RecordingFiles.move(recording.url, into: saveDirectory())
            }
            // Its working folder is not needed any more.
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func deliver(errorTitle: String, to output: @escaping () async throws -> Void) {
        guard !model.isBusy else { return }
        model.isBusy = true
        Task {
            do {
                try await output()
                window.closeNow()
            } catch {
                model.isBusy = false
                showError(error, errorTitle)
            }
        }
    }

    /// The recording cut to what was trimmed. The file is cut here, once.
    private func trimmedRecording() async throws -> Recording {
        guard history.isTrimmed else { return recording }
        let range = history.current
        // Let go of the file before it is replaced.
        detachPlayer()
        do {
            try await RecordingFiles.trim(recording.url, to: range)
        } catch {
            attachPlayer()
            showTrim()
            throw error
        }
        recording = Recording(
            url: recording.url,
            pointSize: recording.pointSize,
            duration: range.duration.seconds,
            capturedAt: recording.capturedAt
        )
        history = TrimHistory(full: Self.wholeRange(of: recording))
        return recording
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard !model.isBusy else { return false }
        switch menuItem.action {
        case Selector(("undo:")): return history.canUndo
        case Selector(("redo:")): return history.canRedo
        default: return true
        }
    }

    // MARK: - Closing

    fileprivate func requestClose() {
        guard !model.isBusy else { return }
        model.isBusy = true
        Task {
            do {
                result = try await trimmedRecording()
            } catch {
                // Nothing is lost: the recording goes back as it was.
                result = recording
                showError(error, String(localized: "The recording could not be trimmed"))
            }
            window.closeNow()
        }
    }

    func windowWillClose(_ notification: Notification) {
        window.delegate = nil
        detachPlayer()
        let result = result
        self.result = nil
        let notify = onClose
        onClose = nil
        notify?(result)
    }

    final class Window: NSWindow {
        // The close button and ⌘W reach close() through performClose(_:).
        override func close() {
            if let player = delegate as? RecordingPlayerWindowController {
                player.requestClose()
            } else {
                super.close()
            }
        }

        fileprivate func closeNow() {
            super.close()
        }
    }

    // MARK: - Building the window

    private func makeContentView() -> NSView {
        let toolbar = NSHostingView(
            rootView: RecordingToolbarView(
                model: model,
                onTrim: { [weak self] in self?.trim() },
                onUndo: { [weak self] in self?.undo(nil) },
                onRedo: { [weak self] in self?.redo(nil) },
                onCopy: { [weak self] in self?.copyRecording(nil) },
                onSave: { [weak self] in self?.saveDocument(nil) }
            )
        )
        playerView.controlsStyle = .inline
        let desk = RecordingDeskView(playerView: playerView, videoSize: recording.pointSize)
        let separator = NSBox()
        separator.boxType = .separator

        let container = NSView()
        for view in [desk, toolbar, separator] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: EditorToolbarView.height),

            separator.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            desk.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            desk.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            desk.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            desk.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private static func wholeRange(of recording: Recording) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: CMTime(seconds: recording.duration, preferredTimescale: 600))
    }

    static func initialContentSize(for videoSize: CGSize, screenSize: CGSize) -> CGSize {
        let maximum = CGSize(width: screenSize.width * 0.85, height: screenSize.height * 0.85)
        let margin = (RecordingDeskView.padding + EditorPrintView.border) * 2
        let player = RecordingDeskView.minimumPlayerSize
        let wanted = CGSize(
            width: max(videoSize.width, player.width) + margin,
            height: max(videoSize.height, player.height) + margin + EditorToolbarView.height
        )
        return CGSize(
            width: max(min(wanted.width, maximum.width), minimumContentWidth),
            height: max(min(wanted.height, maximum.height), minimumVideoHeight + EditorToolbarView.height)
        )
    }
}

/// The editor's dotted desk, with the video on it as a print: as large as
/// fits, but never larger than it was recorded, and in its own proportions.
final class RecordingDeskView: NSView {
    static let padding: CGFloat = 24
    /// Room for the player's controls, and for its trim handles. A smaller
    /// recording is shown larger, or with bars beside it.
    static let minimumPlayerSize = CGSize(width: 420, height: 236)

    private let desk = EditorDeskView()
    private let printView = NSView()
    private let videoSize: CGSize
    private let paper = CALayer()

    init(playerView: AVPlayerView, videoSize: CGSize) {
        self.videoSize = videoSize
        super.init(frame: .zero)
        addSubview(desk)

        printView.wantsLayer = true
        // A layer of its own, under the player's: AppKit leaves it alone.
        printView.layer?.addSublayer(paper)
        CALayer.withoutAnimation {
            paper.backgroundColor = ThumbnailStyle.paper
            paper.cornerRadius = 10
            paper.cornerCurve = .continuous
            paper.borderWidth = 0.5
            paper.borderColor = CGColor(gray: 0, alpha: 0.12)
            paper.shadowColor = CGColor(gray: 0, alpha: 1)
            paper.shadowOpacity = 0.3
            paper.shadowRadius = 14
            paper.shadowOffset = CGSize(width: 0, height: -6)
        }
        playerView.wantsLayer = true
        playerView.layer?.cornerRadius = 4
        playerView.layer?.masksToBounds = true
        printView.addSubview(playerView)
        addSubview(printView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RecordingDeskView is created in code only")
    }

    override func layout() {
        super.layout()
        desk.frame = bounds
        let border = EditorPrintView.border
        let available = bounds.insetBy(dx: Self.padding + border, dy: Self.padding + border)
        let factor = min(
            1,
            available.width / max(videoSize.width, 1),
            available.height / max(videoSize.height, 1)
        )
        let video = CGSize(
            width: max((videoSize.width * factor).rounded(), min(Self.minimumPlayerSize.width, available.width), 1),
            height: max((videoSize.height * factor).rounded(), min(Self.minimumPlayerSize.height, available.height), 1)
        )
        let printSize = CGSize(width: video.width + border * 2, height: video.height + border * 2)
        printView.frame = CGRect(
            x: (bounds.midX - printSize.width / 2).rounded(),
            y: (bounds.midY - printSize.height / 2).rounded(),
            width: printSize.width,
            height: printSize.height
        )
        printView.subviews.first?.frame = CGRect(x: border, y: border, width: video.width, height: video.height)
        CALayer.withoutAnimation {
            paper.frame = printView.bounds
            // Given the shape, Core Animation does not have to work it out
            // from the pixels.
            paper.shadowPath = CGPath(roundedRect: printView.bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
        }
    }
}
