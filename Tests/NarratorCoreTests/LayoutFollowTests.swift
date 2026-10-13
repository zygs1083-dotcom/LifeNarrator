import Foundation
import Testing
@testable import NarratorCore

private let followWindow = WindowGeometry(frame: CGRect(x: 100, y: 100, width: 600, height: 500))
private let followScreen = CGRect(x: 0, y: 25, width: 1000, height: 800)
private let followHighlight = CGRect(x: 200, y: 300, width: 100, height: 24)
private let followFrame = CGRect(x: 320, y: 300, width: 160, height: 40)

@Test func followTranslatesAllGeometryWithoutRepositioning() throws {
    let line = CGRect(x: 150, y: 300, width: 150, height: 24)
    let obstacles = [line, CGRect(x: 150, y: 350, width: 300, height: 24)]
    let result = try #require(BubblePlacement.follow(highlight: followHighlight, frame: followFrame,
        line: line, obstacles: obstacles, delta: CGPoint(x: 15, y: -80),
        window: followWindow, visibleFrame: followScreen))
    #expect(result.highlight == followHighlight.offsetBy(dx: 15, dy: -80))
    #expect(result.frame == followFrame.offsetBy(dx: 15, dy: -80))
    #expect(result.line == line.offsetBy(dx: 15, dy: -80))
    #expect(result.obstacles == obstacles.map { $0.offsetBy(dx: 15, dy: -80) })
}

@Test func followRemovesWhenHighlightPartlyCrossesContentTopOrBottom() {
    for y in [followWindow.contentArea.minY - followHighlight.minY - 0.5,
              followWindow.contentArea.maxY - followHighlight.maxY + 0.5] {
        #expect(BubblePlacement.follow(highlight: followHighlight, frame: followFrame,
            line: nil, obstacles: [], delta: CGPoint(x: 0, y: y),
            window: followWindow, visibleFrame: followScreen) == nil)
    }
    for y in [followWindow.contentArea.minY - followHighlight.minY,
              followWindow.contentArea.maxY - followHighlight.maxY] {
        #expect(BubblePlacement.follow(highlight: followHighlight, frame: followFrame,
            line: nil, obstacles: [], delta: CGPoint(x: 0, y: y),
            window: followWindow, visibleFrame: followScreen) != nil)
    }
}

@Test func followRemovesWhenBubbleCrossesAnyVisibleScreenEdge() {
    let screen = CGRect(x: 180, y: 200, width: 310, height: 160)
    let window = WindowGeometry(frame: CGRect(x: 0, y: 100, width: 1000, height: 600))
    for delta in [CGPoint(x: -140.5, y: 0), CGPoint(x: 10.5, y: 0),
                  CGPoint(x: 0, y: -100.5), CGPoint(x: 0, y: 20.5)] {
        #expect(BubblePlacement.follow(highlight: followHighlight, frame: followFrame,
            line: nil, obstacles: [], delta: delta, window: window, visibleFrame: screen) == nil)
    }
    #expect(BubblePlacement.follow(highlight: followHighlight, frame: followFrame,
        line: nil, obstacles: [], delta: .zero, window: window, visibleFrame: screen) != nil)
}
