import AppKit
import NarratorCore
import SwiftUI
import XCTest
@testable import NarratorMac

/// Renders every shape × theme × size, anchored composites, and all clear groups on light/dark backgrounds under
/// $SNAPSHOT_DIR for eyeballing; the assertions only check that something was rendered.
@MainActor
final class BubbleSnapshotTests: XCTestCase {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] ?? ".build/snapshots")

    override func setUp() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func testEveryShapeThemeAndSize() throws {
        for shape in BubbleShape.allCases {
            for theme in ColorTheme.allCases {
                for size in BubbleSize.allCases {
                    var a = appearance(shape: shape, theme: theme, size: size, text: "又要上班了！", language: "zh")
                    if shape == .speech {
                        a.tailBelowBody = size.speechTailHeight
                        a.setAppLevelTail(corner: .topRight)
                    }
                    let png = try render(BubbleBodyView(appearance: a).padding(40))
                    XCTAssertFalse(png.isEmpty)
                    try png.write(to: directory.appendingPathComponent("\(shape.rawValue)-\(theme.rawValue)-\(size.rawValue).png"))
                }
            }
        }
    }

    func testAnchoredComposites() throws {
        let canvas = CGRect(x: 0, y: 0, width: 360, height: 220)
        let window = WindowGeometry(frame: canvas, chromeHeight: 0)
        let highlight = BubblePlacement.spriteFrame(around: CGRect(x: 150, y: 170, width: 48, height: 20))
        for shape in BubbleShape.allCases {
            var a = appearance(shape: shape, theme: .clear, size: .medium, text: "Pig Boss incoming", language: "en")
            let placement = try XCTUnwrap(BubblePlacement.anchoredSprite(size: a.outerSize, frame: highlight, line: highlight, window: window, visibleFrame: canvas, occupied: [], obstacles: []))
            if shape == .speech {
                a.setAnchoredTail(frame: placement.frame, highlight: highlight, side: placement.side)
            }
            let decor = AnchorDecor(highlight: highlight, bubbleFrame: placement.frame, side: placement.side, shape: shape, size: .medium, group: a.group)
            let view = ZStack(alignment: .topLeading) {
                Color.white
                AnchorDecorView(decor: decor)
                BubbleBodyView(appearance: a).position(x: placement.frame.midX, y: placement.frame.midY)
            }
            .frame(width: canvas.width, height: canvas.height)
            let png = try render(view)
            XCTAssertFalse(png.isEmpty)
            try png.write(to: directory.appendingPathComponent("anchored-\(shape.rawValue).png"))
        }
    }

    func testSpriteColorsOnLightAndDarkBackgrounds() throws {
        XCTAssertEqual(BubbleStyle().theme, .clear)
        let canvas = CGRect(x: 0, y: 0, width: 520, height: 180)
        let window = WindowGeometry(frame: canvas, chromeHeight: 0)
        let target = CGRect(x: 40, y: 72, width: 100, height: 20)
        let highlight = BubblePlacement.spriteFrame(around: target)
        for index in ColorTheme.clear.palette.indices {
            let a = appearance(shape: .text, theme: .clear, size: .small, text: "又在给钱包放血", language: "zh", groupIndex: index)
            let placement = try XCTUnwrap(BubblePlacement.anchoredSprite(size: a.outerSize, frame: highlight, line: highlight, window: window, visibleFrame: canvas, occupied: [], obstacles: []))
            XCTAssertEqual(placement.side, .right)
            let decor = AnchorDecor(highlight: highlight, bubbleFrame: placement.frame, side: placement.side, shape: .text, size: .small, group: a.group)
            for dark in [false, true] {
                let view = ZStack(alignment: .topLeading) {
                    Color(PaletteColor(hex: dark ? 0x1E1E1E : 0xFFFFFF))
                    Text("¥1,299.00")
                        .font(.system(size: 16))
                        .foregroundStyle(dark ? Color.white : Color.black)
                        .position(x: target.midX, y: target.midY)
                    AnchorDecorView(decor: decor)
                    BubbleBodyView(appearance: a).position(x: placement.frame.midX, y: placement.frame.midY)
                }
                .frame(width: canvas.width, height: canvas.height)
                let png = try render(view)
                XCTAssertFalse(png.isEmpty)
                try png.write(to: directory.appendingPathComponent("sprite-clear-\(index)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private func appearance(shape: BubbleShape, theme: ColorTheme, size: BubbleSize, text: String, language: String, groupIndex: Int = 0) -> BubbleAppearance {
        let group = theme == .random ? ColorSelection.randomGroup(baseHue: 200, index: 0) : theme.palette[groupIndex]
        return BubbleAppearance.make(
            shape: shape, size: size, theme: theme, group: group, effects: [.outline, .shadow],
            font: BubbleFonts.font(choice: .persona, persona: .sharp, language: language, size: size.fontSize),
            text: text, emoji: ["😩", "☕"], quipID: text)
    }

    private func render<V: View>(_ view: V) throws -> Data {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }
}
