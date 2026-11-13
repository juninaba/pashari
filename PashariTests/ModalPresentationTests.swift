import AppKit
import Testing

@testable import Pashari

@MainActor
struct ModalPresentationTests {
    @Test func presentationEndsTheSelectionOnAllDisplaysBeforeShowingTheDialog() throws {
        let screen = try #require(NSScreen.main)
        let first = OverlayPanel(screen: screen)
        let second = OverlayPanel(screen: screen)
        let hidden = OverlayPanel(screen: screen)
        for (index, panel) in [first, second].enumerated() {
            panel.setFrame(CGRect(x: 50 + index * 120, y: 50, width: 100, height: 80), display: false)
            panel.orderFrontRegardless()
        }
        defer { [first, second, hidden].forEach { $0.close() } }
        try #require(first.isVisible && second.isVisible)
        var cancellations = 0
        let cancel = { [weak first, weak second] in
            cancellations += 1
            first?.orderOut(nil)
            second?.orderOut(nil)
        }
        first.onCancel = cancel
        second.onCancel = cancel
        hidden.onCancel = { Issue.record("An inactive selection was cancelled") }

        var presented = false
        let response = ModalPresentation.run {
            #expect(cancellations == 1)
            #expect(!first.isVisible && !second.isVisible)
            presented = true
            return .alertFirstButtonReturn
        }

        #expect(presented)
        #expect(response == .alertFirstButtonReturn)
    }
}
