import AppKit
import ScreenCaptureKit
import Testing

@testable import Pashari

@MainActor
struct ScrollCaptureControlPanelTests {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let size = CGSize(width: 400, height: 44)

    @Test func theControlsGoUnderTheArea() {
        let area = CGRect(x: 300, y: 300, width: 200, height: 300)

        let frame = ScrollCaptureControlPanel.frame(ofSize: size, nextTo: area, in: screen)

        #expect(frame == CGRect(x: 200, y: 300 - 12 - 44, width: 400, height: 44))
    }

    @Test func theControlsGoOverTheAreaWhenThereIsNoRoomUnderIt() {
        let area = CGRect(x: 300, y: 20, width: 200, height: 300)

        let frame = ScrollCaptureControlPanel.frame(ofSize: size, nextTo: area, in: screen)

        #expect(frame.minY == area.maxY + 12)
    }

    @Test func theControlsGoInsideAnAreaThatFillsTheScreen() {
        let frame = ScrollCaptureControlPanel.frame(ofSize: size, nextTo: screen, in: screen)

        #expect(frame.minY == 12)
        #expect(screen.contains(frame))
    }

    @Test func theControlsStayOnScreenBesideAnAreaAtTheEdge() {
        let area = CGRect(x: 0, y: 300, width: 100, height: 300)

        let frame = ScrollCaptureControlPanel.frame(ofSize: size, nextTo: area, in: screen)

        #expect(frame.minX == 12)
    }

    @Test func theBarAsksToWaitUntilRecordingHasBegun() {
        let controls = ScrollCaptureControlPanel()
        #expect(texts(in: controls.contentView).contains(String(localized: "Getting ready…")))

        controls.show(size: CGSize(width: 300, height: 900), status: .recording)
        #expect(texts(in: controls.contentView).contains(String(localized: "Scroll to capture more")))
    }

    private func texts(in view: NSView?) -> [String] {
        guard let view else { return [] }
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { texts(in: $0) }
    }

    @Test func aWiderPictureMayBeLessTall() {
        #expect(ScrollRecorder.maximumHeight(forWidth: 1600) == 30_000)
        #expect(ScrollRecorder.maximumHeight(forWidth: 6000) == 10_000)
    }
}

/// These record a real window while it scrolls, so they run only where
/// Pashari has the Screen Recording permission.
@MainActor
@Suite(.serialized, .enabled(if: CGPreflightScreenCaptureAccess(), "needs the Screen Recording permission"))
struct ScrollRecorderTests {
    @Test func scrollingAWindowJoinsItsContentIntoOneTallPicture() async throws {
        let page = try await ScrollingPage.show()
        defer { page.close() }
        let progress = ProgressLog()
        let recorder = try await page.makeRecorder(reportingTo: progress)

        try await recorder.start()
        try await progress.wait { $0.pictureHeight > 0 }
        for step in 1...10 {
            page.scroll(to: CGFloat(step) * 40)
            try await Task.sleep(for: .milliseconds(100))
        }
        let image = try #require(await recorder.stop())

        // The header and footer once, and everything that scrolled past.
        #expect(image.width == Int(page.area.width * recorder.scale))
        #expect(image.height == Int((page.area.height + 400) * recorder.scale))
        #expect(!progress.reports.contains { $0.isLost })
    }

    @Test func aJumpTooFarIsReportedUntilTheContentIsScrolledBack() async throws {
        let page = try await ScrollingPage.show()
        defer { page.close() }
        let progress = ProgressLog()
        let recorder = try await page.makeRecorder(reportingTo: progress)

        try await recorder.start()
        try await progress.wait { $0.pictureHeight > 0 }
        page.scroll(to: 40)
        try await Task.sleep(for: .milliseconds(150))
        // Further than the scrolling part is tall.
        page.scroll(to: 40 + ScrollingPage.visibleHeight + 100)
        try await progress.wait { $0.isLost }
        page.scroll(to: 80)
        try await progress.wait { !$0.isLost }
        let image = try #require(await recorder.stop())

        #expect(image.height == Int((page.area.height + 80) * recorder.scale))
    }
}

/// A window with a fixed header and footer around a part that scrolls,
/// above other apps' windows.
@MainActor
private final class ScrollingPage {
    static let width: CGFloat = 300
    static let headerHeight: CGFloat = 30
    static let visibleHeight: CGFloat = 200
    static let footerHeight: CGFloat = 20

    let window: NSWindow
    let scrollView: NSScrollView

    /// The whole window, in points from the top-left corner of its display.
    var area: CGRect {
        let screen = window.screen!.frame
        return CGRect(
            x: window.frame.minX - screen.minX,
            y: screen.maxY - window.frame.maxY,
            width: window.frame.width,
            height: window.frame.height
        )
    }

    private init(window: NSWindow, scrollView: NSScrollView) {
        self.window = window
        self.scrollView = scrollView
    }

    static func show() async throws -> ScrollingPage {
        let screen = try #require(NSScreen.main)
        let height = headerHeight + visibleHeight + footerHeight
        let window = NSWindow(
            contentRect: CGRect(
                x: screen.visibleFrame.minX + 80,
                y: (screen.visibleFrame.maxY - 80 - height).rounded(),
                width: width,
                height: height
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // Without the fade-in, which the first frames would catch halfway.
        window.animationBehavior = .none
        // Above ordinary windows, but not on a level whose windows of
        // Pashari's are left out of screenshots.
        window.level = .modalPanel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        let footer = Label(text: "Footer", frame: CGRect(x: 0, y: 0, width: width, height: footerHeight))
        let scrollView = NSScrollView(
            frame: CGRect(x: 0, y: footerHeight, width: width, height: visibleHeight)
        )
        scrollView.documentView = Stripes(frame: CGRect(x: 0, y: 0, width: width, height: 2000))
        scrollView.hasVerticalScroller = false
        let header = Label(
            text: "Header",
            frame: CGRect(x: 0, y: footerHeight + visibleHeight, width: width, height: headerHeight)
        )
        for view in [footer, scrollView, header] {
            content.addSubview(view)
        }
        window.contentView = content
        window.orderFrontRegardless()

        // The window comes on screen a moment later, once the main thread is
        // free to finish showing it.
        let id = CGWindowID(window.windowNumber)
        for _ in 0..<100 {
            let onScreen = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[CFString: Any]] ?? []
            if onScreen.contains(where: { $0[kCGWindowNumber] as? CGWindowID == id }) {
                return ScrollingPage(window: window, scrollView: scrollView)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("The test window did not come on screen")
        return ScrollingPage(window: window, scrollView: scrollView)
    }

    func makeRecorder(reportingTo log: ProgressLog) async throws -> ScrollRecorder {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayID = try #require(window.screen?.displayID)
        let display = try #require(content.displays.first { $0.displayID == displayID })
        return ScrollRecorder(
            area: area,
            of: display,
            excludingWindows: ScreenCapturer.ownWindowsToHide(in: content),
            onProgress: { progress in
                Task { @MainActor in log.reports.append(progress) }
            },
            onFailure: { error in
                Issue.record(error, "The recording stopped")
            }
        )
    }

    func scroll(to y: CGFloat) {
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        // Draw now rather than at the end of this turn of the run loop.
        window.displayIfNeeded()
    }

    func close() {
        window.orderOut(nil)
    }

    /// Every row of pixels different from every other: its colour, and
    /// where a darker band at its left ends.
    private final class Stripes: NSView {
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let scale = window?.backingScaleFactor ?? 2
            var row = Int((dirtyRect.minY * scale).rounded(.down))
            while CGFloat(row) / scale < dirtyRect.maxY {
                let y = CGFloat(row) / scale
                let rowRect = CGRect(x: 0, y: y, width: bounds.width, height: 1 / scale)
                NSColor(
                    srgbRed: CGFloat(row % 256) / 255,
                    green: CGFloat((row / 256) % 256) / 255,
                    blue: 0.5,
                    alpha: 1
                ).setFill()
                rowRect.fill()
                NSColor(white: 0.1, alpha: 1).setFill()
                CGRect(x: 0, y: y, width: CGFloat((row * 7) % 250) / scale, height: 1 / scale).fill()
                row += 1
            }
        }
    }

    private final class Label: NSView {
        private let text: String

        init(text: String, frame: CGRect) {
            self.text = text
            super.init(frame: frame)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("Label is created in code only")
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.darkGray.setFill()
            bounds.fill()
            (text as NSString).draw(
                at: CGPoint(x: 8, y: 4),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white]
            )
        }
    }
}

@MainActor
private final class ProgressLog {
    var reports: [ScrollRecorder.Progress] = []

    /// Waits up to two seconds for a report that `condition` accepts.
    func wait(for condition: (ScrollRecorder.Progress) -> Bool) async throws {
        for _ in 0..<100 {
            if let latest = reports.last, condition(latest) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("The expected progress was never reported: \(reports)")
    }
}
