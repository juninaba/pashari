import AppKit
import Testing

@testable import Pashari

@MainActor
struct StatusItemTests {
    @Test func whileRecordingTheIconIsAStopButtonInsteadOfTheMenu() throws {
        let coordinator = CaptureCoordinator(thumbnailController: ThumbnailController(), ensurePermission: { false })
        let controller = StatusItemController(
            captureCoordinator: coordinator,
            settingsWindowController: SettingsWindowController()
        )
        let statusItem = try #require(Mirror(reflecting: controller).descendant("statusItem") as? NSStatusItem)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let menu = try #require(statusItem.menu)
        #expect(menu.items.map(\.title).contains(String(localized: "Record Area")))
        #expect(menu.items.map(\.title).contains(String(localized: "Record Window")))

        coordinator.onRecordingChange?(true)
        #expect(statusItem.menu == nil)
        #expect(statusItem.button?.action == NSSelectorFromString("stopRecording"))
        #expect(statusItem.button?.image?.accessibilityDescription == String(localized: "Stop Recording"))

        coordinator.onRecordingChange?(false)
        #expect(statusItem.menu === menu)
        #expect(statusItem.button?.action == nil)
    }
}
