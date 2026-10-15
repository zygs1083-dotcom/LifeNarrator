import Foundation
import Testing
import NarratorCore
@testable import NarratorBrain

private struct LayoutReply: Decodable {
    struct Placement: Decodable {
        let frame: CGRect
        let highlight: CGRect?
        let side: String?
        let narrow: Bool
        let covered: Bool
        let connector: Bool
        let outside: Bool
        let corner: String?
        let stackFrames: [CGRect?]?
        let placement: String
    }
    let result: Placement?
}

@Suite @MainActor struct RPCLayoutScenarios {
    private func exchange(_ method: String, _ params: RPCValue) async throws -> RPCValue {
        var output: [String] = []
        let server = BrainRPCServer { output.append($0) }
        let input = AsyncThrowingStream<String, any Error>.makeStream()
        input.continuation.yield(try RPCValue.object(["jsonrpc": .string("2.0"), "id": .string("layout"),
            "method": .string(method), "params": params]).line())
        input.continuation.finish()
        try await server.run(lines: input.stream)
        let response = try JSONDecoder().decode([String: RPCValue].self, from: Data(#require(output.first).utf8))
        #expect(response["id"] == .string("layout"))
        return try #require(response["result"])
    }

    @Test func sizeTierRoundTripDowngradesAndReturnsNull() async throws {
        for (width, height, expected) in [(800.0, 600.0, RPCValue.string("large")),
            (500, 400, .string("medium")), (400, 400, .string("small")), (350, 400, .null), (800, 200, .null)] {
            let params: RPCValue = .object(["requested": .string("large"), "window": try .encode(
                WindowGeometry(frame: CGRect(x: -100, y: 50, width: width, height: height)))])
            #expect(try await exchange("layout.sizeTier", params) == expected)
        }
    }

    private func place(window: WindowGeometry, visible: CGRect, anchor: CGRect? = nil,
                       obstacles: [CGRect] = [], occupied: [CGRect] = [], stack: [CGSize] = []) async throws -> LayoutReply.Placement? {
        func size(_ w: CGFloat, _ h: CGFloat) -> RPCValue { .object(["w": .number(Decimal(Double(w))), "h": .number(Decimal(Double(h)))]) }
        let params: RPCValue = .object(["size": size(240, 24), "narrowSize": size(160, 44),
            "anchor": try .encode(anchor), "line": try .encode(anchor), "window": try .encode(window),
            "visibleFrame": try .encode(visible), "occupied": try .encode(occupied), "obstacles": try .encode(obstacles),
            "inkInset": size(0, 0), "stackSizes": .array(stack.map { size($0.width, $0.height) })])
        return try RPCValue.object(["result": await exchange("layout.place", params)]).decode(LayoutReply.self).result
    }

    @Test func anchoredRoundTripIncludesExpandedHighlightAndPlacementFlags() async throws {
        let window = WindowGeometry(frame: CGRect(x: 300, y: 100, width: 600, height: 600), chromeHeight: 0)
        let anchor = CGRect(x: 550, y: 300, width: 100, height: 20)
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 800)
        let direct = try #require(await place(window: window, visible: screen, anchor: anchor))
        #expect(direct.frame == CGRect(x: 480, y: 324, width: 240, height: 24))
        #expect(direct.highlight == BubblePlacement.spriteFrame(around: anchor))
        #expect(direct.side == "below" && !direct.narrow && !direct.covered && !direct.outside)
        #expect(direct.connector && direct.placement == "below")
        for (visible, side, outside) in [(screen, "right", true),
            (CGRect(x: 0, y: 25, width: 900, height: 800), "left", true), (window.frame, "below", false)] {
            let result = try #require(await place(window: window, visible: visible, anchor: anchor, obstacles: [window.frame]))
            #expect(result.side == side && result.outside == outside && result.covered == !outside)
            #expect(result.narrow && result.connector)
            #expect(result.placement == (outside ? (side == "right" ? "outsideRight" : "outsideLeft") : "covered"))
        }
        #expect(try await place(window: window, visible: window.frame, anchor: anchor, occupied: [window.frame]) == nil)
    }

    @Test func appStackRoundTripRestacksAndDropsInvisibleSlots() async throws {
        let window = WindowGeometry(frame: CGRect(x: 900, y: 100, width: 800, height: 600), chromeHeight: 80)
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 800)
        let stack = [CGSize(width: 180, height: 300), CGSize(width: 180, height: 300), CGSize(width: 180, height: 300)]
        let result = try #require(await place(window: window, visible: screen, stack: stack))
        let expected = BubblePlacement.appStack(sizes: [CGSize(width: 240, height: 24)] + stack, window: window, visibleFrame: screen)
        #expect(result.corner == "topLeft" && result.placement == "corner")
        #expect(result.frame == expected.frames[0])
        #expect(result.stackFrames == expected.frames)
        #expect(result.stackFrames?.last == .some(nil))
        #expect(result.highlight == nil && result.side == nil && !result.connector && !result.outside)
        #expect(try await place(window: window, visible: CGRect(x: 0, y: 0, width: 10, height: 10)) == nil)
    }
}
