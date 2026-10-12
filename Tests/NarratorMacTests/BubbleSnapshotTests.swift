import AppKit
import NarratorCore
import SwiftUI
import XCTest
@testable import NarratorMac

/// Renders every shape × theme × size (and one anchored composite per shape) to PNGs under
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
        let highlight = BubblePlacement.highlightBox(around: CGRect(x: 150, y: 170, width: 48, height: 20))
        for shape in BubbleShape.allCases {
            var a = appearance(shape: shape, theme: .macaron, size: .medium, text: "Pig Boss incoming", language: "en")
            let placement = try XCTUnwrap(BubblePlacement.anchored(size: a.outerSize, highlight: highlight, window: window, visibleFrame: canvas, occupied: []))
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

    private func appearance(shape: BubbleShape, theme: ColorTheme, size: BubbleSize, text: String, language: String) -> BubbleAppearance {
        let group = theme == .random ? ColorSelection.randomGroup(baseHue: 200, index: 0) : theme.palette[0]
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
