import Foundation
import ApplicationServices
import NarratorCore
@testable import NarratorMac
import XCTest

final class ContextTextTests: XCTestCase {
    func testUnavailableVisibleCharacterRangeReturnsNilButOtherErrorsThrow() throws {
        XCTAssertNil(try AXAccess.attributeValue(nil, result: .illegalArgument, name: kAXVisibleCharacterRangeAttribute))
        XCTAssertNil(try AXAccess.attributeValue(nil, result: .attributeUnsupported, name: kAXVisibleCharacterRangeAttribute))
        let text = "整段文字" as CFString
        XCTAssertEqual(try AXAccess.attributeValue(text, result: .success, name: kAXValueAttribute) as? String, "整段文字")
        XCTAssertThrowsError(try AXAccess.attributeValue(nil, result: .cannotComplete, name: kAXVisibleCharacterRangeAttribute))
    }

    func testDHashUsesAllEightRowsAndAdjacentColumns() {
        XCTAssertEqual(TextGeometry.dHash([UInt8](repeating: 100, count: 72)), 0)
        let rising = (0..<8).flatMap { _ in (0..<9).map(UInt8.init) }
        XCTAssertEqual(TextGeometry.dHash(rising), 0)
        XCTAssertEqual(TextGeometry.dHash((0..<8).flatMap { _ in (0..<9).reversed().map(UInt8.init) }), UInt64.max)
        var pixels = [UInt8](repeating: 0, count: 72)
        pixels[0] = 1
        pixels[7 * 9 + 7] = 1
        XCTAssertEqual(TextGeometry.dHash(pixels), 1 | (UInt64(1) << 63))
    }

    func testVisionRectFlipsYAxisAndUsesWindowPoints() {
        let window = CGRect(x: -1200, y: -100, width: 1000, height: 500)
        XCTAssertEqual(TextGeometry.screenRect(CGRect(x: 0, y: 0, width: 1, height: 1), in: window), window)
        let rect = TextGeometry.screenRect(CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25), in: window)
        XCTAssertEqual(rect, CGRect(x: -950, y: 25, width: 500, height: 125))
        XCTAssertEqual(TextGeometry.screenRect(CGRect(x: 0, y: 0, width: 0.1, height: 0.1), in: window).minY, 350, accuracy: 1e-10)
    }

    func testLinesSortTopToBottomThenLeftToRightAndDeduplicateExactPairs() {
        let left = CGRect(x: 10, y: 20, width: 40, height: 16)
        let right = CGRect(x: 100, y: 20, width: 40, height: 16)
        let lines = [TextLine(text: "下方", rect: CGRect(x: 0, y: 60, width: 40, height: 16)),
                     TextLine(text: "张三", rect: right), TextLine(text: "张三", rect: left),
                     TextLine(text: "张三", rect: left), TextLine(text: "李四", rect: left),
                     TextLine(text: "", rect: left)]
        XCTAssertEqual(TextGeometry.sortedIndices(lines), [2, 4, 1, 0])
    }

    func testLineLimitAppliesAfterOrderingAndDeduplication() {
        let lines = (0..<305).reversed().map { TextLine(text: "第\($0)行", rect: CGRect(x: 0, y: $0, width: 40, height: 16)) }
        let indices = TextGeometry.sortedIndices([lines[0]] + lines)
        XCTAssertEqual(indices.count, 300)
        XCTAssertEqual(([lines[0]] + lines)[indices.first!].text, "第0行")
        XCTAssertEqual(([lines[0]] + lines)[indices.last!].text, "第299行")
    }

    func testTrimAndCharacterLimitPreserveUTF16OffsetForAX() {
        let trimmed = TextGeometry.trimmedText(" \n\t张三 👩‍💻 \n")
        XCTAssertEqual(trimmed.text, "张三 👩‍💻")
        XCTAssertEqual(trimmed.utf16Offset, 3)
        XCTAssertEqual(TextGeometry.trimmedText(String(repeating: "👩‍💻", count: 201)).text.count, 200)
        XCTAssertEqual(TextGeometry.trimmedText(" \n").text, "")
    }
}
