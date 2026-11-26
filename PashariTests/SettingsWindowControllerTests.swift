import AppKit
import SwiftUI
import Testing
@testable import Pashari

@Suite(.serialized)
struct SettingsWindowControllerTests {
    @Test func contentSizeKeepsFullHeightWhenDisplayIsTallEnough() {
        let model = SettingsModel()
        let natural = SettingsView.naturalContentSize(for: model)
        #expect(natural.width == SettingsView.width)
        #expect(natural.height > 700)

        let titlebarHeight: CGFloat = 28
        let tallVisibleFrame = CGRect(x: 0, y: 40, width: 1_920, height: natural.height + titlebarHeight + 100)
        let fitted = SettingsWindowController.contentSize(
            for: natural,
            fitting: tallVisibleFrame,
            frameRect: { CGRect(origin: $0.origin, size: CGSize(width: $0.width, height: $0.height + titlebarHeight)) },
            contentRect: { CGRect(origin: $0.origin, size: CGSize(width: $0.width, height: $0.height - titlebarHeight)) }
        )

        #expect(fitted == natural)
    }

    @Test func contentSizeClampsToShortDisplaySoEntireWindowFitsVisibleFrame() {
        let model = SettingsModel()
        let natural = SettingsView.naturalContentSize(for: model)
        let titlebarHeight: CGFloat = 28
        // 1280x800 display minus menu bar and Dock leaves ~730 pt visible height.
        let shortVisibleFrame = CGRect(x: 0, y: 45, width: 1_280, height: 730)

        let fitted = SettingsWindowController.contentSize(
            for: natural,
            fitting: shortVisibleFrame,
            frameRect: { CGRect(origin: $0.origin, size: CGSize(width: $0.width, height: $0.height + titlebarHeight)) },
            contentRect: { CGRect(origin: $0.origin, size: CGSize(width: $0.width, height: $0.height - titlebarHeight)) }
        )

        #expect(fitted.width == SettingsView.width)
        #expect(fitted.height < natural.height)

        let frameSize = CGSize(width: fitted.width, height: fitted.height + titlebarHeight)
        let origin = NSWindow.originCentering(frameSize, in: shortVisibleFrame)
        let windowFrame = CGRect(origin: origin, size: frameSize)
        #expect(windowFrame.minY >= shortVisibleFrame.minY)
        #expect(windowFrame.maxY <= shortVisibleFrame.maxY)
    }

    @Test func tallSettingsWindowFitsWithoutScrolling() {
        let model = SettingsModel()
        let natural = SettingsView.naturalContentSize(for: model)
        let hostingController = NSHostingController(rootView: SettingsView(model: model))
        hostingController.sizingOptions = []

        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.setContentSize(natural)
        window.layoutIfNeeded()

        let scrollView = firstScrollView(in: hostingController.view)
        #expect(scrollView != nil)
        if let scrollView, let documentView = scrollView.documentView {
            #expect(documentView.frame.height <= scrollView.contentView.bounds.height + 1)
        }
    }

    @Test func clampedSettingsWindowScrollsToFullContentHeight() {
        let model = SettingsModel()
        let natural = SettingsView.naturalContentSize(for: model)
        let hostingController = NSHostingController(rootView: SettingsView(model: model))
        hostingController.sizingOptions = []

        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        let shortVisibleFrame = CGRect(x: 0, y: 45, width: 1_280, height: 700)
        let fitted = SettingsWindowController.contentSize(
            for: natural,
            fitting: shortVisibleFrame,
            frameRect: { window.frameRect(forContentRect: $0) },
            contentRect: { window.contentRect(forFrameRect: $0) }
        )
        window.setContentSize(fitted)
        window.layoutIfNeeded()

        #expect(window.frame.height <= shortVisibleFrame.height)
        #expect(window.contentLayoutRect.height < natural.height)

        let scrollView = firstScrollView(in: hostingController.view)
        #expect(scrollView != nil)
        if let scrollView, let documentView = scrollView.documentView {
            #expect(documentView.frame.height > scrollView.contentView.bounds.height)
            // Verify scrolling to the bottom brings the bottom of the document
            // (including Record Fullscreen) into the visible clip rect.
            let maxScrollY = documentView.frame.height - scrollView.contentView.bounds.height
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: maxScrollY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            #expect(scrollView.documentVisibleRect.maxY >= documentView.frame.height - 1)
        }
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}
