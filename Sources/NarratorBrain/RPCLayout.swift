import Foundation
import NarratorCore

private struct RPCSize: Decodable {
    let w: CGFloat
    let h: CGFloat
    var size: CGSize { CGSize(width: w, height: h) }
}

private struct RPCPlace: Decodable {
    let size: RPCSize
    let narrowSize: RPCSize?
    let anchor: CGRect?
    let line: CGRect?
    let window: WindowGeometry
    let visibleFrame: CGRect
    let occupied: [CGRect]
    let obstacles: [CGRect]
    let inkInset: RPCSize
    let stackSizes: [RPCSize]
}

private struct RPCPlacement: Encodable {
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

enum RPCLayout {
    static func sizeTier(_ params: RPCValue) throws -> RPCValue {
        struct Params: Decodable { let requested: BubbleSize; let window: WindowGeometry }
        let p = try params.decode(Params.self)
        return try .encode(BubblePlacement.sizeTier(requested: p.requested, window: p.window))
    }

    static func place(_ params: RPCValue) throws -> RPCValue {
        let p = try params.decode(RPCPlace.self)
        guard p.size.w > 0, p.size.h > 0, p.inkInset.w >= 0, p.inkInset.h >= 0,
              p.narrowSize.map({ $0.w > 0 && $0.h > 0 }) ?? true,
              p.stackSizes.allSatisfy({ $0.w > 0 && $0.h > 0 }) else {
            throw BrainRPCError(code: -32602, message: "Bubble sizes must be positive and inkInset nonnegative")
        }
        if let anchor = p.anchor {
            let highlight = BubblePlacement.spriteFrame(around: anchor)
            guard let result = BubblePlacement.anchoredSprite(size: p.size.size, frame: highlight,
                line: p.line ?? highlight, window: p.window, visibleFrame: p.visibleFrame,
                occupied: p.occupied, obstacles: p.obstacles, narrowSize: p.narrowSize?.size,
                inkInset: p.inkInset.size) else { return .null }
            let side: String
            switch result.side { case .above: side = "above"; case .below: side = "below"; case .right: side = "right"; case .left: side = "left" }
            let placement: String
            if result.covered { placement = "covered" }
            else if result.outside { placement = result.side == .right ? "outsideRight" : "outsideLeft" }
            else {
                switch result.side {
                case .above: placement = "above"
                case .below: placement = "below"
                case .left: placement = "leftMargin"
                case .right: placement = result.connector ? "rightMargin" : abs(result.frame.minX - highlight.maxX - 8) < 1 ? "right" : "lineEnd"
                }
            }
            return try .encode(RPCPlacement(frame: result.frame, highlight: highlight, side: side,
                narrow: result.narrow, covered: result.covered, connector: result.connector, outside: result.outside,
                corner: nil, stackFrames: nil, placement: placement))
        }
        let layout = BubblePlacement.appStack(sizes: [p.size.size] + p.stackSizes.map(\.size),
                                               window: p.window, visibleFrame: p.visibleFrame)
        guard let frame = layout.frames[0] else { return .null }
        return try .encode(RPCPlacement(frame: frame, highlight: nil, side: nil, narrow: false,
            covered: false, connector: false, outside: false,
            corner: layout.corner == .topRight ? "topRight" : "topLeft", stackFrames: layout.frames, placement: "corner"))
    }
}
