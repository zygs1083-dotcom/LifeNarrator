import Foundation
import XCTest
@testable import NarratorCore

final class LayoutColorTests: XCTestCase {
    func testFixedPalettesHaveSixGroups() {
        for theme in [ColorTheme.macaron, .candy, .neon, .starry] {
            XCTAssertEqual(theme.palette.count, 6, theme.rawValue)
        }
        XCTAssertTrue(ColorTheme.random.palette.isEmpty)
        XCTAssertEqual(ColorTheme.neon.palette[0].text, ColorTheme.neon.palette[0].stroke)
    }

    func testStarryPaletteTextContrast() {
        func luminance(_ color: PaletteColor) -> Double {
            let channels = [color.red, color.green, color.blue].map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        for group in ColorTheme.starry.palette {
            XCTAssertGreaterThanOrEqual((luminance(group.text) + 0.05) / (luminance(group.fill) + 0.05), 4.5)
        }
    }

    func testHexDecoding() {
        let c = PaletteColor(hex: 0x1F5A46)
        XCTAssertEqual(c.red, 31 / 255, accuracy: 1e-9)
        XCTAssertEqual(c.green, 90 / 255, accuracy: 1e-9)
        XCTAssertEqual(c.blue, 70 / 255, accuracy: 1e-9)
    }

    func testHSBConversion() {
        let red = PaletteColor(hue: 0, saturation: 1, brightness: 1)
        XCTAssertEqual(red, PaletteColor(red: 1, green: 0, blue: 0))
        let green = PaletteColor(hue: 120, saturation: 1, brightness: 1)
        XCTAssertEqual(green, PaletteColor(red: 0, green: 1, blue: 0))
        let wrapped = PaletteColor(hue: 480, saturation: 1, brightness: 1)
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
        XCTAssertEqual(ColorSelection.randomGroup(baseHue: 300, index: 1).fill, PaletteColor(hue: 77.5, saturation: 0.35, brightness: 1))
    }

    func testAnglesAreStableAndInRange() {
        XCTAssertEqual(stickerAngle(quipID: "x"), stickerAngle(quipID: "x"))
        for id in ["a", "b", "c", "又要上班了！", "builtin.app.dingtalk/3"] {
            XCTAssertTrue((-3...3).contains(stickerAngle(quipID: id)))
            XCTAssertTrue((-4...4).contains(noteAngle(quipID: id)))
        }
    }
    func testClearPaletteContrastAndHSBValues() {
        XCTAssertEqual(ColorTheme.clear.palette.count, 12)
        func luminance(_ color: PaletteColor) -> Double {
            let channels = [color.red, color.green, color.blue].map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        for (group, hue) in zip(ColorTheme.clear.palette, ColorTheme.clearHues) {
            XCTAssertEqual(group.fill, PaletteColor(hue: hue, saturation: 0.22, brightness: 1))
            XCTAssertEqual(group.text, PaletteColor(hue: hue, saturation: 0.78, brightness: 0.40))
            XCTAssertEqual(group.stroke, PaletteColor(hue: hue, saturation: 0.62, brightness: 0.96))
            XCTAssertGreaterThanOrEqual((luminance(group.fill) + 0.05) / (luminance(group.text) + 0.05), 5.8)
        }
    }

    func testSpriteColorsExcludeOccupiedRecentAndCloseHuesReproducibly() {
        var a = SeededRandom(seed: 41)
        var b = SeededRandom(seed: 41)
        let occupied: Set<Int> = [0, 5]
        let recent = [2, 8, 9]
        var selected: Set<Int> = []
        for _ in 0..<100 {
            let index = ColorSelection.spriteGroupIndex(count: 12, occupied: occupied, recent: recent, hueOf: { ColorTheme.clearHues[$0] }, using: &a)
            XCTAssertEqual(index, ColorSelection.spriteGroupIndex(count: 12, occupied: occupied, recent: recent, hueOf: { ColorTheme.clearHues[$0] }, using: &b))
            XCTAssertFalse(occupied.contains(index))
            XCTAssertFalse(recent.suffix(2).contains(index))
            for other in occupied {
                let delta = abs(ColorTheme.clearHues[index] - ColorTheme.clearHues[other])
                XCTAssertGreaterThanOrEqual(min(delta, 360 - delta), 45)
            }
            selected.insert(index)
        }
        XCTAssertEqual(selected, [2, 3, 4, 7, 10])
    }

    func testSpriteOtherThemesExcludeOnlyLastRecentAndHaveFallbacks() {
        var random = SeededRandom(seed: 7)
        var selected: Set<Int> = []
        for _ in 0..<100 {
            selected.insert(ColorSelection.spriteGroupIndex(count: 6, occupied: [0, 1, 2, 3], recent: [4, 5], using: &random))
        }
        XCTAssertEqual(selected, [4])
        XCTAssertEqual(ColorSelection.spriteGroupIndex(count: 6, occupied: [0, 1, 2, 3, 4], recent: [5], using: &random), 5)
        XCTAssertTrue((0..<6).contains(ColorSelection.spriteGroupIndex(count: 6, occupied: Set(0..<6), recent: [], using: &random)))
        XCTAssertEqual(ColorSelection.spriteGroupIndex(count: 12, occupied: Set(0..<11), recent: [11], hueOf: { ColorTheme.clearHues[$0] }, using: &random), 11)
    }

}
