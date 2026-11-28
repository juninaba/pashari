import AppKit
import Testing

@testable import Pashari

struct PinnedScreenshotLayoutTests {
    private let screen = CGRect(x: -1440, y: 50, width: 1440, height: 900)

    @Test func pictureOverlaysCaptureAtItsActualPointSize() {
        let capture = CGRect(x: -1150, y: 300, width: 400, height: 200)
        let placement = PinnedScreenshotLayout.initialPlacement(
            imageSize: capture.size, captureFrame: capture, visibleFrame: screen
        )

        #expect(placement.imageFrame == capture)
        #expect(screen.contains(placement.frame))
    }

    @Test func paperAndToolbarStayVisibleWhenCaptureIsNearAnEdge() {
        let capture = CGRect(x: screen.minX, y: screen.minY, width: 120, height: 100)
        let placement = PinnedScreenshotLayout.initialPlacement(
            imageSize: capture.size, captureFrame: capture, visibleFrame: screen
        )

        #expect(placement.frame.origin == screen.origin)
        #expect(placement.imageFrame.size == capture.size)
    }

    @Test func tallCaptureFitsOnScreenWithRoomForAllItsActions() {
        let placement = PinnedScreenshotLayout.initialPlacement(
            imageSize: CGSize(width: 500, height: 5000), captureFrame: nil, visibleFrame: screen
        )

        #expect(placement.imageSize.width < 100)
        #expect(abs(placement.imageSize.height / placement.imageSize.width - 10) < 0.001)
        #expect(placement.frame.width == PinnedScreenshotLayout.minimumCardWidth)
        #expect(placement.frame.midX == screen.midX)
        #expect(placement.frame.midY == screen.midY)
        #expect(screen.insetBy(dx: -0.001, dy: -0.001).contains(placement.frame))
    }

    @Test func aSecondPinLeavesAnEdgeOfTheFirstPinVisible() {
        let capture = CGRect(x: -1150, y: 300, width: 400, height: 200)
        let first = PinnedScreenshotLayout.initialPlacement(
            imageSize: capture.size, captureFrame: capture, visibleFrame: screen
        )
        let second = PinnedScreenshotLayout.initialPlacement(
            imageSize: capture.size, captureFrame: capture, visibleFrame: screen, occupiedFrames: [first.frame]
        )

        #expect(first.frame.intersects(second.frame))
        #expect(first.frame.origin != second.frame.origin)
        #expect(screen.contains(second.frame))
    }

    @Test func aSecondPinOffsetsFromAnOriginRoundedByAppKit() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1024, height: 799)
        let imageSize = CGSize(width: 160, height: 100)
        let first = PinnedScreenshotLayout.initialPlacement(
            imageSize: imageSize, captureFrame: nil, visibleFrame: visibleFrame
        )
        var displayedFrame = first.frame
        displayedFrame.origin.y.round()

        let second = PinnedScreenshotLayout.initialPlacement(
            imageSize: imageSize, captureFrame: nil, visibleFrame: visibleFrame, occupiedFrames: [displayedFrame]
        )

        #expect(abs(second.frame.minY - displayedFrame.minY) >= 1)
    }

    @Test func aSecondScreenFillingPinLeavesRoomToReachTheFirst() {
        let imageSize = CGSize(width: 1424, height: 856)
        let first = PinnedScreenshotLayout.initialPlacement(
            imageSize: imageSize, captureFrame: nil, visibleFrame: screen
        )
        let second = PinnedScreenshotLayout.initialPlacement(
            imageSize: imageSize, captureFrame: nil, visibleFrame: screen, occupiedFrames: [first.frame]
        )

        #expect(first.frame == screen)
        #expect(first.frame.contains(second.frame))
        #expect(second.frame.minY > first.frame.minY + PinnedScreenshotLayout.toolbarHeight / 2)
        #expect(abs(second.imageSize.width / second.imageSize.height - imageSize.width / imageSize.height) < 0.001)
    }

    @Test(arguments: [[856, 856, 854], Array(repeating: 856, count: 7)])
    func aLargePinLeavesTheEarlierPinsReachable(heights: [Int]) {
        var occupied: [CGRect] = []
        for height in heights {
            let pin = PinnedScreenshotLayout.initialPlacement(
                imageSize: CGSize(width: 1424, height: CGFloat(height)), captureFrame: nil,
                visibleFrame: screen, occupiedFrames: occupied
            )

            #expect(screen.contains(pin.frame))
            #expect(!occupied.contains { pin.frame.contains($0) })
            occupied.append(pin.frame)
        }
    }

    @Test func shorterPinsAtTheSameOriginStillLeaveAnEarlierPinReachable() {
        let captures = [
            CGRect(x: -1370, y: 108, width: 1300, height: 800),
            CGRect(x: -1370, y: 108, width: 1300, height: 760),
            CGRect(x: -1370, y: 148, width: 1300, height: 760),
        ]
        var frames: [CGRect] = []
        for capture in captures {
            frames.append(PinnedScreenshotLayout.initialPlacement(
                imageSize: capture.size, captureFrame: capture, visibleFrame: screen, occupiedFrames: frames
            ).frame)
        }

        let first = frames[0]
        let corner = CGPoint(x: first.minX + 12, y: first.minY + 12)
        #expect(!frames.dropFirst().contains { $0.contains(corner) })
    }

    @Test func zoomKeepsThePointUnderThePointerStill() {
        let capture = CGRect(x: -1100, y: 350, width: 300, height: 200)
        let placement = PinnedScreenshotLayout.initialPlacement(
            imageSize: capture.size, captureFrame: capture, visibleFrame: screen
        )
        let anchor = CGPoint(x: capture.minX + 50, y: capture.midY)
        let zoomed = PinnedScreenshotLayout.zoomed(
            placement, originalSize: capture.size, by: 1.5, at: anchor, in: screen
        )

        #expect(zoomed.imageSize == CGSize(width: 450, height: 300))
        #expect(zoomed.imageFrame.minX == anchor.x - 75)
        #expect(zoomed.imageFrame.midY == anchor.y)
    }

    @Test func switchingToASmallerDisplayMovesAndScalesThePinToFit() {
        let capture = CGRect(x: -1350, y: 100, width: 1100, height: 750)
        let placement = PinnedScreenshotLayout.initialPlacement(
            imageSize: capture.size, captureFrame: capture, visibleFrame: screen
        )
        let fallback = CGRect(x: 0, y: 80, width: 800, height: 500)
        let moved = PinnedScreenshotLayout.relocated(placement, in: fallback)

        #expect(fallback.contains(moved.frame))
        #expect(moved.imageSize.height == 456)
        #expect(abs(moved.imageSize.width / moved.imageSize.height - 1100.0 / 750) < 0.001)
    }

    @Test func movingDisplaysKeepsTheZoomWhenThePinFits() {
        let capture = CGRect(x: -1150, y: 300, width: 400, height: 200)
        let placement = PinnedScreenshotLayout.initialPlacement(
            imageSize: capture.size, captureFrame: capture, visibleFrame: screen
        )
        let fallback = CGRect(x: 0, y: 50, width: 1000, height: 800)
        let moved = PinnedScreenshotLayout.relocated(placement, in: fallback)

        #expect(fallback.contains(moved.frame))
        #expect(moved.imageSize == placement.imageSize)
    }
}

@MainActor
struct PinnedScreenshotPanelTests {
    @Test func nonActivatingPanelStillExposesItsActionsToAccessibility() throws {
        let placement = PinnedScreenshotLayout.initialPlacement(
            imageSize: CGSize(width: 300, height: 190), captureFrame: nil,
            visibleFrame: CGRect(x: 0, y: 0, width: 900, height: 700)
        )
        let panel = PinnedScreenshotPanel(imageSize: placement.imageSize, placement: placement)
        defer { panel.close() }
        let content = try #require(panel.contentView)
        content.layoutSubtreeIfNeeded()

        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.level == ThumbnailPanel.windowLevel)
        #expect(panel.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary]))
        let buttons = content.subviews.compactMap { $0 as? NSButton }
        #expect(buttons.map { $0.accessibilityLabel() } == [
            String(localized: "Copy"), String(localized: "Save"),
            String(localized: "Annotate"), String(localized: "Unpin"),
        ])
        var didCopy = false
        panel.onCopy = { didCopy = true }
        let copy = try #require(buttons.first)
        _ = copy.accessibilityPerformPress()
        #expect(didCopy)
    }

    @Test func endingAFileDragOutsideThePinClearsTheHover() throws {
        let placement = PinnedScreenshotLayout.initialPlacement(
            imageSize: CGSize(width: 300, height: 190), captureFrame: nil,
            visibleFrame: CGRect(x: 0, y: 0, width: 900, height: 700)
        )
        let panel = PinnedScreenshotPanel(imageSize: placement.imageSize, placement: placement)
        defer { panel.close() }
        let pointer = NSEvent.mouseLocation
        panel.setFrameOrigin(CGPoint(x: pointer.x + 1000, y: pointer.y + 1000))
        try #require(!panel.frame.contains(NSEvent.mouseLocation))
        let content = try #require(panel.contentView)
        let handle = try #require(content.subviews.compactMap { $0 as? ThumbnailPreviewView }.first)
        let icon = try #require(content.subviews.compactMap { $0 as? NSImageView }.first)
        let enter = try #require(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))
        content.mouseEntered(with: enter)
        #expect(icon.alphaValue == 1)

        handle.dragDidEnd(operation: .copy)

        #expect(icon.alphaValue == 0)
    }
}
