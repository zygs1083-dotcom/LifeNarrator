import Foundation
import XCTest
@testable import NarratorCore

final class TextInkTests: XCTestCase {
    func testSingleLineChineseEnglishAndMixedWidths() {
        let rect = CGRect(x: 100, y: 200, width: 200, height: 20)
        for (text, width) in [("中文测试字", 110.0), ("abcdefghij", 110.0), ("中文abc", 77.0)] {
            let ink = TextInk.rects(for: TextLine(text: text, rect: rect), medianHeight: 20)
            XCTAssertEqual(ink, [CGRect(x: 96, y: 199, width: width + 8, height: 22)])
        }
        XCTAssertEqual(TextInk.weight("Ａあ한中a"), 9)
        XCTAssertEqual(TextInk.rects(for: TextLine(text: String(repeating: "中", count: 20), rect: rect), medianHeight: 20),
                       [rect.insetBy(dx: -4, dy: -1)])
    }

    func testMultilineLastWidthAndClamping() {
        let rect = CGRect(x: 100, y: 200, width: 110, height: 60)
        for (count, width) in [(25, 55.0), (10, 11.0), (40, 110.0)] {
            let ink = TextInk.rects(for: TextLine(text: String(repeating: "a", count: count), rect: rect), medianHeight: 20)
            XCTAssertEqual(ink, [CGRect(x: 96, y: 199, width: 118, height: 42),
                                 CGRect(x: 96, y: 239, width: width + 8, height: 22)])
        }
    }

    func testRowRoundingAndSingleLineThreshold() {
        for (height, rows) in [(30.0, 1), (31.0, 2), (49.0, 2), (50.0, 3)] {
            let rect = CGRect(x: 0, y: 0, width: 110, height: height)
            let ink = TextInk.rects(for: TextLine(text: "abc", rect: rect), medianHeight: 20)
            XCTAssertEqual(ink.count, rows == 1 ? 1 : 2)
            if rows == 1 {
                XCTAssertEqual(ink[0].height, height + 2)
            } else {
                XCTAssertEqual(ink[0].height, Double(rows - 1) * 20 + 2)
                XCTAssertEqual(ink[1].minY, Double(rows - 1) * 20 - 1)
            }
        }
    }
}
