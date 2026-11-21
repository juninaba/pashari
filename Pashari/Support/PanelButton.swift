import AppKit

/// A push button that works on the first click, even while another app is
/// active.
final class PanelButton: NSButton {
    var handler: (() -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        target = self
        action = #selector(performAction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PanelButton is created in code only")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func performAction() {
        handler?()
    }
}
