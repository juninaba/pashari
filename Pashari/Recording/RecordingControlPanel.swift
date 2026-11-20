import AppKit

/// The small bar next to the area of a recording. While the frame is
/// adjusted it shows the frame's size, Cancel and Record; while recording,
/// how long and how large the recording is so far, and Stop.
///
/// It never takes the keyboard: while the frame is adjusted the overlay
/// has it, for Return and Escape, and while recording the app being
/// recorded keeps it, so that what the user types reaches that app.
final class RecordingControlPanel: NSPanel {
    enum Status: Equatable {
        /// The frame's size, in points.
        case adjusting(CGSize)
        /// Recording has not begun yet.
        case preparing
        /// `bytes` is how much of the recording is on disk.
        case recording(elapsed: TimeInterval, bytes: Int)
    }

    var onRecord: (() -> Void)?
    var onCancel: (() -> Void)?
    var onStop: (() -> Void)?

    private(set) var status: Status = .preparing
    private let dot = NSView()
    private let primaryLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")
    private let cancelButton = PanelButton(title: String(localized: "Cancel"))
    private let recordButton = PanelButton(title: String(localized: "Record"))
    private let stopButton = PanelButton(title: String(localized: "Stop"))

    private static let preparingText = String(localized: "Getting ready…")

    init() {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = OverlayPanel.windowLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        hidesOnDeactivate = false
        worksWhenModal = true
        isReleasedWhenClosed = false
        // It may sit over something the user wants to see.
        isMovableByWindowBackground = true
        appearance = NSAppearance(named: .darkAqua)
        contentView = makeContent()
        show(.adjusting(.zero))
    }

    override var canBecomeKey: Bool { false }

    func show(_ status: Status) {
        self.status = status
        switch status {
        case .adjusting(let size):
            primaryLabel.stringValue = "\(Int(size.width)) × \(Int(size.height))"
        case .preparing:
            primaryLabel.stringValue = Self.preparingText
        case .recording(let elapsed, let bytes):
            primaryLabel.stringValue = "\(Self.time(elapsed)) / \(Self.time(RecordingWriter.maximumDuration.seconds))"
            secondaryLabel.stringValue = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
        let isAdjusting = if case .adjusting = status { true } else { false }
        let isRecording = if case .recording = status { true } else { false }
        dot.isHidden = isAdjusting
        dot.layer?.backgroundColor = (isRecording ? NSColor.systemRed : NSColor.secondaryLabelColor).cgColor
        secondaryLabel.isHidden = !isRecording
        cancelButton.isHidden = !isAdjusting
        recordButton.isHidden = !isAdjusting
        stopButton.isHidden = isAdjusting
        setContentSize(contentView?.fittingSize ?? frame.size)
    }

    /// Once the user has decided, the buttons have done their part.
    func disableButtons() {
        [cancelButton, recordButton, stopButton].forEach { $0.isEnabled = false }
    }

    /// "0:12", "4:59".
    static func time(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private func makeContent() -> NSView {
        let background = NSVisualEffectView()
        // The frosted look of the system's floating panels. `.active` keeps
        // it from turning grey because Pashari is not the active app.
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        primaryLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        primaryLabel.textColor = .labelColor
        secondaryLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        secondaryLabel.textColor = .secondaryLabelColor
        secondaryLabel.alignment = .right

        cancelButton.handler = { [weak self] in self?.onCancel?() }
        // Shown as the default button. Return reaches the overlay, which
        // has the keyboard, and does the same.
        recordButton.keyEquivalent = "\r"
        recordButton.handler = { [weak self] in self?.onRecord?() }
        stopButton.handler = { [weak self] in self?.onStop?() }

        let stack = NSStackView(views: [dot, primaryLabel, secondaryLabel, cancelButton, recordButton, stopButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.setCustomSpacing(16, after: primaryLabel)
        stack.setCustomSpacing(20, after: secondaryLabel)
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)

        // Wide enough for every text they can show, so that the bar keeps
        // its size while recording, and its buttons their place.
        let longestTime = "\(Self.time(599)) / \(Self.time(599))"
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            primaryLabel.widthAnchor.constraint(
                equalToConstant: Self.width(of: ["00000 × 00000", Self.preparingText, longestTime], in: primaryLabel)
            ),
            secondaryLabel.widthAnchor.constraint(
                equalToConstant: Self.width(of: ["000.0 MB", "1,000 KB"], in: secondaryLabel)
            ),
        ])
        return background
    }

    private static func width(of texts: [String], in label: NSTextField) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: label.font as Any]
        return ceil(texts.map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0) + 4
    }
}
