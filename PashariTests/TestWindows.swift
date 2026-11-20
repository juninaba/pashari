import AppKit
import ScreenCaptureKit
import Testing

@testable import Pashari

/// Tests that show windows on the real screen, or end every overlay as a
/// dialog does, take turns: side by side, one could cover another's window
/// or end its overlays.
struct TakesTurnsOnTheScreen: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    @concurrent
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        try await ScreenTurn.shared.take(function)
    }
}

extension Trait where Self == TakesTurnsOnTheScreen {
    static var takesTurnsOnTheScreen: Self { Self() }
}

private actor ScreenTurn {
    static let shared = ScreenTurn()
    private var isTaken = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func take(_ body: @concurrent @Sendable () async throws -> Void) async throws {
        if isTaken {
            // The test before hands the turn straight over.
            await withCheckedContinuation { waiting.append($0) }
        } else {
            isTaken = true
        }
        defer {
            if waiting.isEmpty {
                isTaken = false
            } else {
                waiting.removeFirst().resume()
            }
        }
        try await body()
    }
}

/// An opaque panel of Pashari's at the level of its overlays.
@MainActor
enum Cover {
    static func show(over frame: CGRect) async throws -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = OverlayPanel.windowLevel
        panel.backgroundColor = .systemRed
        panel.isOpaque = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        try await waitUntilOnScreen(panel)
        return panel
    }
}

/// A window comes on screen a moment after it is ordered front, once the
/// main thread is free to finish showing it.
@MainActor
func waitUntilOnScreen(_ window: NSWindow) async throws {
    let id = CGWindowID(window.windowNumber)
    for _ in 0..<100 {
        let onScreen = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[CFString: Any]] ?? []
        if onScreen.contains(where: { $0[kCGWindowNumber] as? CGWindowID == id }) {
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("The test window did not come on screen")
}

extension TestImages.RGBA {
    func isClose(to other: TestImages.RGBA, within tolerance: Int) -> Bool {
        [(red, other.red), (green, other.green), (blue, other.blue)].allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
    }

    /// Colours this display shows as they are, unlike the purest blue.
    static let pageBlue = TestImages.RGBA(red: 40, green: 90, blue: 200, alpha: 255)
    static let pageRed = TestImages.RGBA(red: 200, green: 60, blue: 40, alpha: 255)
}

/// A window of one colour above other apps' windows, away from the pointer,
/// which the recording would show.
@MainActor
final class ColorPage {
    static let size = CGSize(width: 240, height: 160)

    let window: NSWindow

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

    private init(window: NSWindow) {
        self.window = window
    }

    static func show(_ color: TestImages.RGBA) async throws -> ColorPage {
        let screen = try #require(NSScreen.main)
        let visible = screen.visibleFrame
        // On the right, clear of the scroll capture tests' page at the top
        // left, which may be on screen at the same time, and of the pointer.
        let pointerIsLow = NSEvent.mouseLocation.y < visible.midY
        let y = pointerIsLow ? visible.maxY - 80 - size.height : visible.minY + 80
        let window = NSWindow(
            contentRect: CGRect(
                x: (visible.maxX - 80 - size.width).rounded(),
                y: y.rounded(),
                width: size.width,
                height: size.height
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // Without the fade-in, which the first frames would catch halfway.
        window.animationBehavior = .none
        // Above ordinary windows, but not on a level whose windows of
        // Pashari's are left out of recordings.
        window.level = .modalPanel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSView()
        window.contentView?.wantsLayer = true
        let page = ColorPage(window: window)
        page.fill(color)
        window.orderFrontRegardless()
        try await waitUntilOnScreen(window)
        return page
    }

    func fill(_ color: TestImages.RGBA) {
        window.contentView?.layer?.backgroundColor = CGColor(
            srgbRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        )
        window.displayIfNeeded()
    }

    /// Whether `image`, a picture of the page, shows `color`: in most of
    /// five places, because a recording also shows the pointer, which is
    /// wherever the user leaves it.
    func isShowing(_ color: TestImages.RGBA, in image: CGImage) -> Bool {
        Self.samples(of: image).filter { $0.isClose(to: color, within: 12) }.count >= 3
    }

    /// The colours of five places spread over `image`.
    static func samples(of image: CGImage) -> [TestImages.RGBA] {
        [(0.5, 0.5), (0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)].map { x, y in
            TestImages.pixel(of: image, x: Int(Double(image.width) * x), y: Int(Double(image.height) * y))
        }
    }

    /// The recording leaves out the windows of Pashari's, the test host,
    /// that were not listed when it began: the page must be by then.
    func listedContent() async throws -> SCShareableContent {
        let id = CGWindowID(window.windowNumber)
        for _ in 0..<50 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if content.windows.contains(where: { $0.windowID == id }) {
                return content
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("The test window was never listed")
        return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    func close() {
        window.orderOut(nil)
    }
}
