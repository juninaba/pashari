import AppKit
import Testing

@testable import Pashari

@MainActor
@Suite(.serialized)
struct CaptureCoordinatorTests {
    @Test func aModalDialogBlocksAllCaptureModesUntilItCloses() throws {
        var permissionChecks = 0
        let coordinator = CaptureCoordinator(thumbnailController: ThumbnailController()) {
            permissionChecks += 1
            return false
        }
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: .titled,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }

        do {
            let session = NSApp.beginModalSession(for: window)
            defer { NSApp.endModalSession(session) }
            NSApp.runModalSession(session)
            try #require(NSApp.modalWindow === window)

            coordinator.captureArea()
            coordinator.captureText()
            coordinator.captureWindow()
            coordinator.captureFullscreen()
            coordinator.recordArea()
            coordinator.recordWindow()
            coordinator.recordFullscreen()
            #expect(permissionChecks == 0)
        }

        coordinator.captureFullscreen()
        #expect(permissionChecks == 1)
    }

    @Test func anExistingOverlayRemainsEligibleForInputDuringAModalSession() throws {
        let screen = try #require(NSScreen.main)
        let overlay = OverlayPanel(screen: screen)
        overlay.setFrame(CGRect(x: 100, y: 100, width: 180, height: 100), display: false)
        overlay.orderFrontRegardless()
        defer { overlay.orderOut(nil) }

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: .titled,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let modal = NSApp.beginModalSession(for: window)
        defer {
            NSApp.endModalSession(modal)
            window.orderOut(nil)
        }
        NSApp.runModalSession(modal)
        try #require(NSApp.modalWindow === window)
        // AppKit uses this capability to route mouse and keyboard events
        // outside the modal window. Synthetic postEvent clicks don't reliably
        // pass through that system routing in an XCTest host.
        #expect(overlay.worksWhenModal)
    }

    @Test func aRequestWhileThePermissionAlertIsOpenIsIgnored() {
        let state = AlertState()
        let coordinator = CaptureCoordinator(thumbnailController: ThumbnailController()) {
            state.checks += 1
            // The alert is open, and the user presses the hotkey again.
            if state.checks == 1 {
                state.coordinator?.captureFullscreen()
            }
            return false
        }
        state.coordinator = coordinator

        coordinator.captureFullscreen()
        #expect(state.checks == 1)

        coordinator.captureFullscreen()
        #expect(state.checks == 2)
    }

    @Test func onlyACaptureThatEndsInAScreenshotPlaysTheShutterSound() async throws {
        let thumbnails = ThumbnailController()
        defer {
            while let card = thumbnails.cards.first { card.onClose?() }
        }
        var plays = 0
        let coordinator = CaptureCoordinator(
            thumbnailController: thumbnails,
            ensurePermission: { true },
            playShutterSound: { plays += 1 }
        )

        let cancelled = try #require(coordinator.run { nil })
        await cancelled.value
        #expect(plays == 0)

        let taken = try #require(coordinator.run {
            Screenshot(image: TestImages.make(width: 20, height: 10), scale: 1, capturedAt: Date())
        })
        await taken.value
        #expect(thumbnails.pendingCount == 1)
        #expect(plays == 1)
    }

    @Test func textCaptureCopiesOnlyPlainTextWithoutCreatingAThumbnail() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        Clipboard.copy(pngData: Data([0]), to: pasteboard)
        let thumbnails = ThumbnailController()
        var plays = 0
        var feedback: [TextCaptureFeedback] = []
        let coordinator = CaptureCoordinator(
            thumbnailController: thumbnails,
            ensurePermission: { true },
            playShutterSound: { plays += 1 }
        )

        let task = try #require(coordinator.runTextCapture(
            recognize: { _ in "Hello\nこんにちは" },
            pasteboard: pasteboard,
            showFeedback: { feedback.append($0) }
        ) { sampleScreenshot })
        await task.value

        #expect(pasteboard.pasteboardItems?.map(\.types) == [[.string]])
        #expect(pasteboard.string(forType: .string) == "Hello\nこんにちは")
        #expect(thumbnails.pendingCount == 0)
        #expect(plays == 0)
        #expect(feedback == [.copied])
    }

    @Test(arguments: [nil, .noText, .failed] as [TextCaptureFeedback?])
    func textCapturePreservesClipboardWhenNoTextIsCopied(outcome: TextCaptureFeedback?) async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        Clipboard.copy(pngData: Data([0]), to: pasteboard)
        let originalChangeCount = pasteboard.changeCount
        let coordinator = CaptureCoordinator(thumbnailController: ThumbnailController(), ensurePermission: { true })
        var feedback: [TextCaptureFeedback] = []

        let task = try #require(coordinator.runTextCapture(
            recognize: { _ in
                #expect(outcome != nil)
                if outcome == .failed { throw CaptureError.displayNotFound }
                return nil
            },
            pasteboard: pasteboard,
            showFeedback: { feedback.append($0) }
        ) { outcome == nil ? nil : sampleScreenshot })
        await task.value

        #expect(pasteboard.changeCount == originalChangeCount)
        #expect(feedback == (outcome.map { [$0] } ?? []))
    }

    private var sampleScreenshot: Screenshot {
        Screenshot(image: TestImages.make(width: 20, height: 10), scale: 1, capturedAt: Date())
    }

    private final class AlertState {
        var checks = 0
        weak var coordinator: CaptureCoordinator?
    }
}
