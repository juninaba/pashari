import AppKit

enum TextCaptureFeedback {
    case copied
    case noText
    case failed

    private static var panel: NSPanel?

    private var message: String {
        switch self {
        case .copied: String(localized: "Text copied")
        case .noText: String(localized: "No text found")
        case .failed: String(localized: "Could not recognize text")
        }
    }

    func show() {
        guard let screen = NSScreen.underMouse ?? NSScreen.main else { return }
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.sizeToFit()
        label.setFrameOrigin(CGPoint(x: 16, y: 8))

        let background = NSVisualEffectView(frame: CGRect(
            x: 0, y: 0, width: label.frame.width + 32, height: label.frame.height + 16
        ))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.addSubview(label)

        let panel = NSPanel(
            contentRect: background.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = OverlayPanel.windowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.contentView = background
        panel.setFrameOrigin(CGPoint(
            x: screen.visibleFrame.midX - panel.frame.width / 2,
            y: screen.visibleFrame.maxY - panel.frame.height - 12
        ))

        Self.panel?.orderOut(nil)
        Self.panel = panel
        panel.orderFrontRegardless()
        Task {
            try? await Task.sleep(for: .seconds(2))
            panel.orderOut(nil)
            if Self.panel === panel { Self.panel = nil }
        }
    }
}
