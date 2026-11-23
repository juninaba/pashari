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
    /// The frame's size, while it is adjusted.
    private let sizeLabel = NSTextField(labelWithString: "")
    /// "Getting ready…", then how long the recording is so far.
    private let timeLabel = NSTextField(labelWithString: "")
    private let bytesLabel = NSTextField(labelWithString: "")
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
        var isRecording = false
        switch status {
        case .adjusting(let size):
            sizeLabel.stringValue = "\(Int(size.width)) × \(Int(size.height))"
        case .preparing:
            timeLabel.stringValue = Self.preparingText
            bytesLabel.stringValue = ""
        case .recording(let elapsed, let bytes):
            timeLabel.stringValue = "\(Self.time(elapsed)) / \(Self.time(RecordingWriter.maximumDuration.seconds))"
            bytesLabel.stringValue = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            isRecording = true
        }
        let isAdjusting = if case .adjusting = status { true } else { false }
        sizeLabel.isHidden = !isAdjusting
        cancelButton.isHidden = !isAdjusting
        recordButton.isHidden = !isAdjusting
        // The same width from "Getting ready…" on, so that Stop keeps its
        // place.
        for view in [dot, timeLabel, bytesLabel, stopButton] {
            view.isHidden = isAdjusting
        }
        dot.layer?.backgroundColor = (isRecording ? NSColor.systemRed : NSColor.secondaryLabelColor).cgColor
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
        for label in [sizeLabel, timeLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            label.textColor = .labelColor
        }
        bytesLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        bytesLabel.textColor = .secondaryLabelColor
        bytesLabel.alignment = .right

        cancelButton.handler = { [weak self] in self?.onCancel?() }
        // The bar is never key, so no button of it shows as the default
        // one: Record gets the red dot of recording instead. Return reaches
        // the overlay, which has the keyboard, and does the same.
        Self.give(recordButton, symbol: "circle.fill", tint: .systemRed)
        recordButton.handler = { [weak self] in self?.onRecord?() }
        Self.give(stopButton, symbol: "stop.fill", tint: nil)
        stopButton.handler = { [weak self] in self?.onStop?() }

        let stack = NSStackView(views: [sizeLabel, dot, timeLabel, bytesLabel, cancelButton, recordButton, stopButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.setCustomSpacing(20, after: sizeLabel)
        stack.setCustomSpacing(12, after: timeLabel)
        stack.setCustomSpacing(16, after: bytesLabel)
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
            sizeLabel.widthAnchor.constraint(equalToConstant: Self.width(of: ["00000 × 00000"], in: sizeLabel)),
            timeLabel.widthAnchor.constraint(
                equalToConstant: Self.width(of: [Self.preparingText, longestTime], in: timeLabel)
            ),
            bytesLabel.widthAnchor.constraint(
                equalToConstant: Self.width(of: ["000.0 MB", "1,000 KB"], in: bytesLabel)
            ),
        ])
        return background
    }

    /// `tint` is drawn into the symbol: a button of a window that is not
    /// key would draw a tinted symbol white.
    private static func give(_ button: NSButton, symbol: String, tint: NSColor?) {
        var configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        if let tint {
            configuration = configuration.applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = tint == nil
        button.image = image
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
    }

    private static func width(of texts: [String], in label: NSTextField) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: label.font as Any]
        return ceil(texts.map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0) + 4
    }
}
