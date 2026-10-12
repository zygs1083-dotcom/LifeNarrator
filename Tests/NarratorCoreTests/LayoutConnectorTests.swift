import Foundation
import XCTest
@testable import NarratorCore

final class LayoutConnectorTests: XCTestCase {
    let highlight = CGRect(x: 396, y: 397, width: 48, height: 24)

    func testLineAboveAndSuppressedWhenClose() {
        let bubble = CGRect(x: 300, y: 345, width: 240, height: 44)
        let line = BubbleConnector.line(bubble: bubble, highlight: highlight, side: .above)
        XCTAssertEqual(line?.from, CGPoint(x: 420, y: 389))
        XCTAssertEqual(line?.to, CGPoint(x: 420, y: 397))
        let touching = CGRect(x: 300, y: 350, width: 240, height: 44)
        XCTAssertNil(BubbleConnector.line(bubble: touching, highlight: highlight, side: .above))
    }

    func testThoughtDotsShrinkTowardHighlight() {
        let bubble = CGRect(x: 300, y: 300, width: 240, height: 80)
        let dots = BubbleConnector.thoughtDots(bubble: bubble, highlight: highlight, side: .above, cloudHeight: 80)
        XCTAssertEqual(dots.count, 3)
        XCTAssertEqual(dots[0].center, CGPoint(x: 420, y: 384))
        XCTAssertEqual(dots[2].center, CGPoint(x: 420, y: 393))
        for (dot, expected) in zip(dots, [11.2, 7.2, 4.4]) {
            XCTAssertEqual(dot.radius, expected, accuracy: 1e-9)
        }
    }

    func testThoughtDotsCapAt40() {
        let far = CGRect(x: 300, y: 250, width: 240, height: 80)
        let dots = BubbleConnector.thoughtDots(bubble: far, highlight: highlight, side: .above, cloudHeight: 80)
        XCTAssertEqual(dots[2].center.y, 330 + 36)
    }

    func testSpeechTailTipAndRootClamp() {
        let bubble = CGRect(x: 380, y: 345, width: 240, height: 44)
        XCTAssertEqual(BubbleConnector.speechTailTip(bubble: bubble, highlight: highlight, side: .above), CGPoint(x: 420, y: 395))
        let root = BubbleConnector.speechTailRoot(bubble: bubble, highlight: highlight, side: .above, cornerRadius: 14, tailBase: 18)
        XCTAssertEqual(root, 420)
        let shifted = CGRect(x: 415, y: 345, width: 240, height: 44)
        XCTAssertEqual(BubbleConnector.speechTailRoot(bubble: shifted, highlight: highlight, side: .above, cornerRadius: 14, tailBase: 18), 415 + 14 + 9)
    }
}
