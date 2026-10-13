import Foundation
import XCTest
@testable import NarratorCore

final class LayoutPlacementTests: XCTestCase {
    let screen = CGRect(x: 0, y: 25, width: 1440, height: 800)
    let window = WindowGeometry(frame: CGRect(x: 200, y: 100, width: 800, height: 600))
    let size = CGSize(width: 180, height: 44)

    // MARK: §8.1

    func testAppStackTopRightThenStacksDown() {
        let layout = BubblePlacement.appStack(sizes: [size, CGSize(width: 120, height: 40)], window: window, visibleFrame: screen)
        XCTAssertEqual(layout.corner, .topRight)
        XCTAssertEqual(layout.frames[0], CGRect(x: 1000 - 16 - 180, y: 100 + 52 + 12, width: 180, height: 44))
        XCTAssertEqual(layout.frames[1], CGRect(x: 1000 - 16 - 120, y: 164 + 44 + 10, width: 120, height: 40))
    }

    func testAppStackUsesToolbarHeight() {
        let layout = BubblePlacement.appStack(sizes: [size], window: WindowGeometry(frame: window.frame, chromeHeight: 80), visibleFrame: screen)
        XCTAssertEqual(layout.frames[0]?.minY, 100 + 80 + 12)
    }

    func testAppStackFallsBackToTopLeftWhenRightEdgeOffScreen() {
        let offRight = WindowGeometry(frame: CGRect(x: 900, y: 100, width: 800, height: 600))
        let layout = BubblePlacement.appStack(sizes: [size], window: offRight, visibleFrame: screen)
        XCTAssertEqual(layout.corner, .topLeft)
        XCTAssertEqual(layout.frames[0]?.minX, 900 + 16)
    }

    func testAppStackDropsSlotsBelowVisibleFrame() {
        let tall = CGSize(width: 180, height: 300)
        let layout = BubblePlacement.appStack(sizes: [tall, tall, tall], window: window, visibleFrame: screen)
        XCTAssertNotNil(layout.frames[0])
        XCTAssertNotNil(layout.frames[1])
        XCTAssertNil(layout.frames[2])
    }

    // MARK: §8.2

    var highlight: CGRect { BubblePlacement.highlightBox(around: CGRect(x: 400, y: 400, width: 40, height: 18)) }

    func testHighlightBoxExpansion() {
        XCTAssertEqual(highlight, CGRect(x: 396, y: 397, width: 48, height: 24))
    }

    func testAnchoredPrefersAboveCentered() throws {
        let p = try XCTUnwrap(BubblePlacement.anchored(size: size, highlight: highlight, window: window, visibleFrame: screen, occupied: []))
        XCTAssertEqual(p.side, .above)
        XCTAssertEqual(p.frame.midX, highlight.midX)
        XCTAssertEqual(p.frame.maxY, highlight.minY - 8)
    }

    func testAnchoredHonorsCloudGap() throws {
        let p = try XCTUnwrap(BubblePlacement.anchored(size: size, highlight: highlight, window: window, visibleFrame: screen, occupied: [], gap: BubblePlacement.cloudAnchorGap))
        XCTAssertEqual(p.frame.maxY, highlight.minY - 36)
        XCTAssertLessThanOrEqual(BubbleConnector.length(bubble: p.frame, highlight: highlight, side: .above), 40)
    }

    func testAnchoredFlipsBelowWhenNoRoomAbove() throws {
        let hl = BubblePlacement.highlightBox(around: CGRect(x: 400, y: 160, width: 40, height: 18))
        let p = try XCTUnwrap(BubblePlacement.anchored(size: size, highlight: hl, window: window, visibleFrame: screen, occupied: []))
        XCTAssertEqual(p.side, .below)
        XCTAssertEqual(p.frame.minY, hl.maxY + 8)
    }

    func testAnchoredGoesRightWhenNeitherAboveNorBelowFits() throws {
        let short = WindowGeometry(frame: CGRect(x: 200, y: 100, width: 800, height: 130))
        let hl = BubblePlacement.highlightBox(around: CGRect(x: 300, y: 190, width: 40, height: 18))
        let p = try XCTUnwrap(BubblePlacement.anchored(size: size, highlight: hl, window: short, visibleFrame: screen, occupied: []))
        XCTAssertEqual(p.side, .right)
        XCTAssertEqual(p.frame.minX, hl.maxX + 8)
        XCTAssertEqual(p.frame.midY, hl.midY)
    }

    func testAnchoredClampsHorizontallyInsideContentArea() throws {
        let hl = BubblePlacement.highlightBox(around: CGRect(x: 210, y: 400, width: 40, height: 18))
        let p = try XCTUnwrap(BubblePlacement.anchored(size: size, highlight: hl, window: window, visibleFrame: screen, occupied: []))
        XCTAssertEqual(p.frame.minX, window.frame.minX + 8)
    }

    func testAnchoredSkipsWhenHighlightOutsideContentArea() {
        let hl = BubblePlacement.highlightBox(around: CGRect(x: 400, y: 120, width: 40, height: 18))
        XCTAssertNil(BubblePlacement.anchored(size: size, highlight: hl, window: window, visibleFrame: screen, occupied: []))
    }

    func testAnchoredMovesBelowWhenAboveIsOccupied() throws {
        let occupied = CGRect(x: 300, y: 340, width: 300, height: 40)
        let p = try XCTUnwrap(BubblePlacement.anchored(size: size, highlight: highlight, window: window, visibleFrame: screen, occupied: [occupied]))
        XCTAssertEqual(p.side, .below)
    }

    func testAnchoredShiftsSidewaysWhenAboveAndBelowOccupied() throws {
        let above = CGRect(x: 480, y: 340, width: 40, height: 40)
        let below = CGRect(x: 300, y: 420, width: 300, height: 40)
        let p = try XCTUnwrap(BubblePlacement.anchored(size: size, highlight: highlight, window: window, visibleFrame: screen, occupied: [above, below]))
        XCTAssertEqual(p.side, .above)
        XCTAssertEqual(p.frame.maxX, above.minX - 8)
        XCTAssertLessThanOrEqual(BubbleConnector.length(bubble: p.frame, highlight: highlight, side: .above), 40)
    }

    func testAnchoredGivesUpWhenShiftWouldStretchConnector() {
        let above = CGRect(x: 350, y: 340, width: 300, height: 40)
        let below = CGRect(x: 300, y: 420, width: 300, height: 40)
        XCTAssertNil(BubblePlacement.anchored(size: size, highlight: highlight, window: window, visibleFrame: screen, occupied: [above, below]))
    }

    // MARK: §8.3

    func testSizeTierDowngrades() {
        XCTAssertEqual(BubblePlacement.sizeTier(requested: .large, window: window), .large)
        let narrow = WindowGeometry(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        XCTAssertEqual(BubblePlacement.sizeTier(requested: .large, window: narrow), .medium)
        let narrower = WindowGeometry(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertEqual(BubblePlacement.sizeTier(requested: .large, window: narrower), .small)
    }

    func testSizeTierNilForTinyOrShortWindows() {
        XCTAssertNil(BubblePlacement.sizeTier(requested: .small, window: WindowGeometry(frame: CGRect(x: 0, y: 0, width: 350, height: 400))))
        XCTAssertNil(BubblePlacement.sizeTier(requested: .small, window: WindowGeometry(frame: CGRect(x: 0, y: 0, width: 800, height: 200))))
    }
    func testSpriteFrameExpansion() {
        XCTAssertEqual(BubblePlacement.spriteFrame(around: CGRect(x: 400, y: 400, width: 40, height: 18)), CGRect(x: 395, y: 397, width: 50, height: 24))
    }

    func testSpriteTriesSixPositionsInOrderWithoutCoveringTextOrMarks() throws {
        let window = WindowGeometry(frame: CGRect(x: 0, y: 0, width: 640, height: 700), chromeHeight: 0)
        let frame = CGRect(x: 270, y: 300, width: 60, height: 20)
        let line = CGRect(x: 220, y: 300, width: 180, height: 20)
        let size = CGSize(width: 80, height: 30)
        let blockers = [CGRect(x: 370, y: 305, width: 2, height: 2),
                        CGRect(x: 460, y: 305, width: 2, height: 2),
                        CGRect(x: 290, y: 340, width: 2, height: 2),
                        CGRect(x: 290, y: 275, width: 2, height: 2),
                        CGRect(x: 600, y: 305, width: 2, height: 2)]
        let origins = [CGPoint(x: 338, y: 295), CGPoint(x: 408, y: 295), CGPoint(x: 260, y: 324),
                       CGPoint(x: 260, y: 266), CGPoint(x: 552, y: 295), CGPoint(x: 8, y: 295)]
        for i in origins.indices {
            let obstacles = Array(blockers.prefix(i)).map { $0.insetBy(dx: -2, dy: -2) }
            let occupied = [CGRect(x: 150, y: 100, width: 100, height: 30)]
            let p = try XCTUnwrap(BubblePlacement.anchoredSprite(size: size, frame: frame, line: line, window: window,
                visibleFrame: screen, occupied: occupied, obstacles: obstacles))
            XCTAssertEqual(p.frame.origin, origins[i])
            XCTAssertEqual(p.connector, i >= 2)
            XCTAssertFalse(p.narrow)
            XCTAssertFalse(p.covered)
            XCTAssertFalse(p.frame.intersects(frame))
            for obstacle in obstacles { XCTAssertFalse(p.frame.intersects(obstacle)) }
            for other in occupied { XCTAssertFalse(p.frame.intersects(other)) }
        }
    }

    func testSpriteRejectsLongConnectorsAndUsesOtherMargin() throws {
        let window = WindowGeometry(frame: CGRect(x: 0, y: 0, width: 1000, height: 700), chromeHeight: 0)
        let frame = CGRect(x: 190, y: 300, width: 60, height: 20)
        let line = CGRect(x: 100, y: 300, width: 750, height: 20)
        let size = CGSize(width: 80, height: 30)
        let obstacles = [CGRect(x: 100, y: 250, width: 750, height: 120)]
        let p = try XCTUnwrap(BubblePlacement.anchoredSprite(size: size, frame: frame, line: line, window: window,
            visibleFrame: screen, occupied: [CGRect(x: 858, y: 295, width: 80, height: 30)], obstacles: obstacles))
        XCTAssertEqual(p.side, .left)
        XCTAssertLessThanOrEqual(BubbleConnector.length(bubble: p.frame, highlight: frame, side: p.side), 240)
    }

    func testSpriteNarrowRetryUsesMeasuredTwoLineSize() throws {
        let frame = CGRect(x: 650, y: 400, width: 100, height: 20)
        let line = CGRect(x: 210, y: 400, width: 540, height: 20)
        let obstacles = [CGRect(x: 210, y: 200, width: 540, height: 400)]
        let p = try XCTUnwrap(BubblePlacement.anchoredSprite(size: CGSize(width: 260, height: 25), frame: frame, line: line,
            window: window, visibleFrame: screen, occupied: [], obstacles: obstacles, narrowSize: CGSize(width: 160, height: 44)))
        XCTAssertTrue(p.narrow)
        XCTAssertFalse(p.covered)
        XCTAssertEqual(p.frame.size, CGSize(width: 160, height: 44))
        XCTAssertEqual(p.side, .right)
        XCTAssertFalse(p.frame.intersects(obstacles[0]))
    }

    func testSpriteCoveredChoosesSmallestIntersectionAndNeverCoversFrameOrOccupied() throws {
        let window = WindowGeometry(frame: CGRect(x: 0, y: 0, width: 700, height: 700), chromeHeight: 0)
        let frame = CGRect(x: 270, y: 300, width: 60, height: 20)
        let line = CGRect(x: 220, y: 300, width: 180, height: 20)
        let size = CGSize(width: 80, height: 30)
        let obstacles = [CGRect(x: 0, y: 294, width: 700, height: 32),
                         CGRect(x: 250, y: 324, width: 100, height: 40),
                         CGRect(x: 250, y: 266, width: 100, height: 10)]
        let occupied = [CGRect(x: 0, y: 100, width: 50, height: 30)]
        let p = try XCTUnwrap(BubblePlacement.anchoredSprite(size: size, frame: frame, line: line, window: window,
            visibleFrame: screen, occupied: occupied, obstacles: obstacles))
        XCTAssertTrue(p.covered)
        XCTAssertEqual(p.side, .above)
        XCTAssertEqual(p.frame.origin, CGPoint(x: 260, y: 266))
        XCTAssertFalse(p.frame.intersects(frame))
        XCTAssertFalse(p.frame.intersects(occupied[0]))
    }

    func testSpriteUsesVisibleIntersectionAndRejectsNoSpace() throws {
        let visible = CGRect(x: 300, y: 300, width: 500, height: 300)
        let frame = CGRect(x: 680, y: 400, width: 100, height: 24)
        let p = try XCTUnwrap(BubblePlacement.anchoredSprite(size: size, frame: frame, line: frame, window: window,
            visibleFrame: visible, occupied: [], obstacles: []))
        XCTAssertTrue(window.contentArea.intersection(visible).insetBy(dx: 8, dy: 4).contains(p.frame))
        XCTAssertNil(BubblePlacement.anchoredSprite(size: size, frame: frame, line: frame, window: window,
            visibleFrame: CGRect(x: 0, y: 0, width: 50, height: 50), occupied: [], obstacles: []))
        XCTAssertNil(BubblePlacement.anchoredSprite(size: CGSize(width: 1000, height: 900), frame: frame, line: frame,
            window: window, visibleFrame: screen, occupied: [], obstacles: []))
        let small = WindowGeometry(frame: CGRect(x: 0, y: 0, width: 359, height: 500), chromeHeight: 0)
        XCTAssertNil(BubblePlacement.anchoredSprite(size: size, frame: frame, line: frame, window: small,
            visibleFrame: screen, occupied: [], obstacles: []))
        XCTAssertNil(BubblePlacement.anchoredSprite(size: size, frame: frame, line: frame, window: window,
            visibleFrame: screen, occupied: [window.frame], obstacles: []))
    }
}
