import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public struct ThoughtDot: Sendable, Equatable {
    public let center: CGPoint
    public let radius: CGFloat
}

/// Geometry between a highlight box and its bubble (visual-spec §2.2, §2.3, §7).
public enum BubbleConnector {
    /// Midpoints of the two facing edges: the bubble edge nearest the highlight and the highlight edge facing the bubble.
    public static func endpoints(bubble: CGRect, highlight: CGRect, side: AnchorSide) -> (bubble: CGPoint, highlight: CGPoint) {
        switch side {
        case .above: (CGPoint(x: bubble.midX, y: bubble.maxY), CGPoint(x: highlight.midX, y: highlight.minY))
        case .below: (CGPoint(x: bubble.midX, y: bubble.minY), CGPoint(x: highlight.midX, y: highlight.maxY))
        case .right: (CGPoint(x: bubble.minX, y: bubble.midY), CGPoint(x: highlight.maxX, y: highlight.midY))
        case .left: (CGPoint(x: bubble.maxX, y: bubble.midY), CGPoint(x: highlight.minX, y: highlight.midY))
        }
    }

    public static func length(bubble: CGRect, highlight: CGRect, side: AnchorSide) -> CGFloat {
        let (a, b) = endpoints(bubble: bubble, highlight: highlight, side: side)
        return hypot(b.x - a.x, b.y - a.y)
    }

    /// §7 connecting line for rounded / sticker / note. nil when the facing edges are 6pt apart or less.
    public static func line(bubble: CGRect, highlight: CGRect, side: AnchorSide) -> (from: CGPoint, to: CGPoint)? {
        let gap: CGFloat = switch side {
        case .above: highlight.minY - bubble.maxY
        case .below: bubble.minY - highlight.maxY
        case .right: bubble.minX - highlight.maxX
        case .left: highlight.minX - bubble.maxX
        }
        guard gap > 6 else { return nil }
        let (a, b) = endpoints(bubble: bubble, highlight: highlight, side: side)
        return (a, b)
    }

    /// §2.2 three thought dots from the cloud edge toward the highlight, over at most 40pt.
    public static func thoughtDots(bubble: CGRect, highlight: CGRect, side: AnchorSide, cloudHeight: CGFloat) -> [ThoughtDot] {
        let (a, b) = endpoints(bubble: bubble, highlight: highlight, side: side)
        let distance = hypot(b.x - a.x, b.y - a.y)
        let unit = CGPoint(x: (b.x - a.x) / distance, y: (b.y - a.y) / distance)
        let span = min(distance, 40)
        let offsets: [CGFloat] = [4, span / 2, span - 4]
        let radii: [CGFloat] = [0.14, 0.09, 0.055].map { $0 * cloudHeight }
        return zip(offsets, radii).map { offset, radius in
            ThoughtDot(center: CGPoint(x: a.x + unit.x * offset, y: a.y + unit.y * offset), radius: radius)
        }
    }

    /// §2.3 tail tip for an anchored speech bubble: the highlight's facing-edge midpoint, 2pt short of the edge.
    public static func speechTailTip(bubble: CGRect, highlight: CGRect, side: AnchorSide) -> CGPoint {
        let target = endpoints(bubble: bubble, highlight: highlight, side: side).highlight
        return switch side {
        case .above: CGPoint(x: target.x, y: target.y - 2)
        case .below: CGPoint(x: target.x, y: target.y + 2)
        case .right: CGPoint(x: target.x + 2, y: target.y)
        case .left: CGPoint(x: target.x - 2, y: target.y)
        }
    }

    /// §2.3 root-center coordinate along the tail edge (x for top/bottom edges, y for the left edge),
    /// following the highlight center but kept clear of the corners.
    public static func speechTailRoot(bubble: CGRect, highlight: CGRect, side: AnchorSide, cornerRadius: CGFloat, tailBase: CGFloat) -> CGFloat {
        let margin = cornerRadius + tailBase / 2
        return switch side {
        case .above, .below: min(max(highlight.midX, bubble.minX + margin), bubble.maxX - margin)
        case .right, .left: min(max(highlight.midY, bubble.minY + margin), bubble.maxY - margin)
        }
    }
}
