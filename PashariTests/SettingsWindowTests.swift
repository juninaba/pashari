import AppKit
import SwiftUI
import Testing

@testable import Pashari

@MainActor
struct SettingsWindowTests {
    @Test func settingsFitAShorterDisplayAndGrowDownwardAgain() {
        let host = NSHostingController(rootView: SettingsView(model: SettingsModel()))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.setFrameTopLeftPoint(CGPoint(x: 20, y: 850))
        let initialTop = window.frame.maxY

        let tallDisplay = CGRect(x: 0, y: 0, width: 900, height: 1000)
        SettingsWindowController.fit(window, in: tallDisplay)
        let naturalFrame = window.frame
        #expect(naturalFrame.maxY == initialTop)

        let shortDisplay = CGRect(x: 0, y: 50, width: 900, height: naturalFrame.height - 40)
        SettingsWindowController.fit(window, in: shortDisplay)
        let shortenedFrame = window.frame
        #expect(shortDisplay.contains(shortenedFrame))
        #expect(shortenedFrame.height == shortDisplay.height)

        SettingsWindowController.fit(window, in: tallDisplay)
        #expect(window.frame.height > shortenedFrame.height)
        #expect(tallDisplay.contains(window.frame))
        #expect(window.frame.maxY == shortenedFrame.maxY)
    }
}
