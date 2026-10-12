import XCTest
@testable import NarratorCore

final class LayoutColorTests: XCTestCase {
    func testFixedPalettesHaveSixGroups() {
        for theme in [ColorTheme.macaron, .candy, .neon] {
            XCTAssertEqual(theme.palette.count, 6, theme.rawValue)
        }
        XCTAssertTrue(ColorTheme.random.palette.isEmpty)
        XCTAssertEqual(ColorTheme.neon.palette[0].text, ColorTheme.neon.palette[0].stroke)
    }

    func testHexDecoding() {
        let c = RGBColor(hex: 0x1F5A46)
        XCTAssertEqual(c.red, 31 / 255, accuracy: 1e-9)
        XCTAssertEqual(c.green, 90 / 255, accuracy: 1e-9)
        XCTAssertEqual(c.blue, 70 / 255, accuracy: 1e-9)
    }

    func testHSBConversion() {
        let red = RGBColor(hue: 0, saturation: 1, brightness: 1)
        XCTAssertEqual(red, RGBColor(red: 1, green: 0, blue: 0))
        let green = RGBColor(hue: 120, saturation: 1, brightness: 1)
        XCTAssertEqual(green, RGBColor(red: 0, green: 1, blue: 0))
        let wrapped = RGBColor(hue: 480, saturation: 1, brightness: 1)
        XCTAssertEqual(wrapped, green)
    }

    func testGroupIndexAvoidsOccupiedOnce() {
        let hash = stableHash("builtin.app.dingtalk")
        let base = ColorSelection.groupIndex(ruleHash: hash, quipSequence: 0, occupied: [])
        XCTAssertEqual(ColorSelection.groupIndex(ruleHash: hash, quipSequence: 0, occupied: [base]), (base + 1) % 6)
        XCTAssertEqual(ColorSelection.groupIndex(ruleHash: hash, quipSequence: 1, occupied: []), (base + 1) % 6)
    }

    func testRandomGroupsWalkByGoldenAngle() {
        let a = ColorSelection.randomGroup(baseHue: 10, index: 0)
        let b = ColorSelection.randomGroup(baseHue: 10, index: 1)
        XCTAssertEqual(a, ColorSelection.randomGroup(baseHue: 10, index: 0))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(ColorSelection.randomGroup(baseHue: 300, index: 1).fill, RGBColor(hue: 77.5, saturation: 0.35, brightness: 1))
    }

    func testAnglesAreStableAndInRange() {
        XCTAssertEqual(stickerAngle(quipID: "x"), stickerAngle(quipID: "x"))
        for id in ["a", "b", "c", "又要上班了！", "builtin.app.dingtalk/3"] {
            XCTAssertTrue((-3...3).contains(stickerAngle(quipID: id)))
            XCTAssertTrue((-4...4).contains(noteAngle(quipID: id)))
        }
    }
}
