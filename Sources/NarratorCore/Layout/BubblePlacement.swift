import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A front window in screen coordinates (top-left origin, pt), visual-spec §8.
public struct WindowGeometry: Sendable, Equatable {
    public var frame: CGRect
    /// Title bar plus toolbar; 52 is the §8.1 estimate used when AX gives no AXToolbar.
    public var chromeHeight: CGFloat

    public init(frame: CGRect, chromeHeight: CGFloat = 52) {
        self.frame = frame
        self.chromeHeight = chromeHeight
    }

    public var contentArea: CGRect {
        CGRect(x: frame.minX, y: frame.minY + chromeHeight, width: frame.width, height: frame.height - chromeHeight)
    }
}

/// Which side of the highlight box an anchored bubble sits on.
public enum AnchorSide: Sendable, Equatable {
    case above, below, right, left
}

public struct AnchoredPlacement: Sendable, Equatable {
    public let frame: CGRect
    public let side: AnchorSide

    public init(frame: CGRect, side: AnchorSide) {
        self.frame = frame
        self.side = side
    }
}

public struct SpritePlacement: Sendable, Equatable {
    public let frame: CGRect
    public let side: AnchorSide
    public let connector: Bool
    public let covered: Bool
    public let narrow: Bool
    public var outside: Bool = false
}

public enum WindowCorner: Sendable, Equatable {
    case topRight, topLeft
}

public struct AppStackLayout: Sendable, Equatable {
    public let corner: WindowCorner
    /// One entry per input size, newest first; nil when that slot falls outside the visible frame.
    public let frames: [CGRect?]
}

public enum BubblePlacement {
    public static let edgeMargin: CGFloat = 8
    public static let anchorGap: CGFloat = 8
    /// Clouds need room for the three §2.2 thought dots, which the 8pt gap cannot hold; stays under the 40pt connector cap.
    public static let cloudAnchorGap: CGFloat = 36
    public static let maxConnectorLength: CGFloat = 40
    public static let minimumWindowSize = CGSize(width: 360, height: 200)

    /// §8.3 size-tier downgrade. nil means "show nothing in this window".
    public static func sizeTier(requested: BubbleSize, window: WindowGeometry) -> BubbleSize? {
        guard window.frame.width >= minimumWindowSize.width, window.frame.height >= minimumWindowSize.height else { return nil }
        let content = window.contentArea
        var tier: BubbleSize? = requested
        while let t = tier, content.width < 1.5 * t.maxWidth || content.height < 160 {
            tier = t.smaller
        }
        return tier
    }

    /// §7: hit-text rect grown by 4pt horizontally and 3pt vertically.
    public static func highlightBox(around textRect: CGRect) -> CGRect {
        textRect.insetBy(dx: -4, dy: -3)
    }

    public static func spriteFrame(around textRect: CGRect) -> CGRect {
        textRect.insetBy(dx: -5, dy: -3)
    }

    public static func anchoredSprite(size: CGSize, frame: CGRect, line: CGRect, window: WindowGeometry,
                                      visibleFrame: CGRect, occupied: [CGRect], obstacles: [CGRect],
                                      narrowSize: CGSize? = nil, inkInset: CGSize = .zero) -> SpritePlacement? {
        let bounds = window.contentArea.intersection(visibleFrame)
        guard !bounds.isNull, window.frame.width >= minimumWindowSize.width,
              window.frame.height >= minimumWindowSize.height else { return nil }
        let inner = bounds.insetBy(dx: 8, dy: 4)
        func candidates(_ size: CGSize, narrow: Bool) -> [SpritePlacement] {
            let origins: [(AnchorSide, CGPoint, Bool)] = [
                (.right, CGPoint(x: frame.maxX + 8, y: frame.midY - size.height / 2), false),
                (.right, CGPoint(x: line.maxX + 8, y: line.midY - size.height / 2), false),
                (.below, CGPoint(x: frame.midX - size.width / 2, y: line.maxY + 4), true),
                (.above, CGPoint(x: frame.midX - size.width / 2, y: line.minY - 4 - size.height), true),
                (.right, CGPoint(x: inner.maxX - size.width, y: frame.midY - size.height / 2), true),
                (.left, CGPoint(x: inner.minX, y: frame.midY - size.height / 2), true),
            ]
            return origins.map { side, origin, connector in
                let x = min(max(origin.x, inner.minX), inner.maxX - size.width)
                let bubble = CGRect(x: x, y: origin.y, width: size.width, height: size.height)
                return SpritePlacement(frame: bubble, side: side, connector: connector, covered: false, narrow: narrow)
            }
        }
        func fits(_ placement: SpritePlacement) -> Bool {
            inner.contains(placement.frame) && !placement.frame.intersects(frame)
                && !occupied.contains { $0.insetBy(dx: -4, dy: -4).intersects(placement.frame) }
                && (!placement.connector || BubbleConnector.length(bubble: placement.frame, highlight: frame, side: placement.side) <= 240)
        }
        func clear(_ placement: SpritePlacement) -> Bool {
            // `inkInset` is the transparent padding of the text-only style; only the glyphs may not touch text.
            fits(placement) && !obstacles.contains { $0.insetBy(dx: 1, dy: 1).intersects(placement.frame.insetBy(dx: inkInset.width, dy: inkInset.height)) }
        }
        var choices = candidates(size, narrow: false)
        if let placement = choices.first(where: clear) { return placement }
        // The caller measures the same text at the 160pt width before the retry.
        if let narrowSize {
            choices = candidates(narrowSize, narrow: true)
            if let placement = choices.first(where: clear) { return placement }
        }
        let outsideSize = narrowSize ?? size
        for side in [AnchorSide.right, .left] {
            let x = side == .right ? window.frame.maxX + 12 : window.frame.minX - 12 - outsideSize.width
            let bubble = CGRect(x: x, y: frame.midY - outsideSize.height / 2,
                                width: outsideSize.width, height: outsideSize.height)
            if visibleFrame.contains(bubble), !bubble.intersects(frame),
               !occupied.contains(where: { $0.insetBy(dx: -4, dy: -4).intersects(bubble) }),
               BubbleConnector.length(bubble: bubble, highlight: frame, side: side) <= 400 {
                return SpritePlacement(frame: bubble, side: side, connector: true, covered: false,
                                       narrow: narrowSize != nil, outside: true)
            }
        }
        func overlap(_ placement: SpritePlacement) -> CGFloat {
            obstacles.reduce(0) { area, obstacle in
                let shared = obstacle.insetBy(dx: 1, dy: 1).intersection(placement.frame.insetBy(dx: inkInset.width, dy: inkInset.height))
                return area + (shared.isNull ? 0 : shared.width * shared.height)
            }
        }
        let fallback = [choices[2], choices[3], choices[1]].filter(fits)
        guard let placement = fallback.enumerated().min(by: {
            let a = overlap($0.element), b = overlap($1.element)
            return a == b ? $0.offset < $1.offset : a < b
        })?.element else { return nil }
        return SpritePlacement(frame: placement.frame, side: placement.side, connector: placement.connector,
                               covered: true, narrow: placement.narrow)
    }

    /// §8.1 app-level stack. `sizes` is ordered newest first; the newest takes the top slot.
    public static func appStack(sizes: [CGSize], window: WindowGeometry, visibleFrame: CGRect) -> AppStackLayout {
        func frames(_ corner: WindowCorner) -> [CGRect] {
            var y = window.contentArea.minY + 12
            return sizes.map { size in
                let x = corner == .topLeft ? window.frame.minX + 16 : window.frame.maxX - 16 - size.width
                defer { y += size.height + 10 }
                return CGRect(origin: CGPoint(x: x, y: y), size: size)
            }
        }
        // The bubble zone is the right 320pt of the window; if that sticks out of the screen use the left corner.
        let rightZoneVisible = window.frame.maxX <= visibleFrame.maxX && window.frame.maxX - 320 >= visibleFrame.minX
        var corner: WindowCorner = rightZoneVisible ? .topRight : .topLeft
        var result = frames(corner)
        if let first = result.first, !visibleFrame.contains(first) {
            corner = corner == .topRight ? .topLeft : .topRight
            result = frames(corner)
        }
        return AppStackLayout(corner: corner, frames: result.map { visibleFrame.contains($0) ? $0 : nil })
    }

    /// §8.2 anchored placement. `highlight` is the box from `highlightBox(around:)`, `occupied` the
    /// frames of bubbles already on screen. nil means "skip this narration".
    public static func anchored(size: CGSize, highlight: CGRect, window: WindowGeometry, visibleFrame: CGRect, occupied: [CGRect], gap: CGFloat = anchorGap) -> AnchoredPlacement? {
        let bounds = window.contentArea.intersection(visibleFrame)
        guard bounds.contains(highlight) else { return nil }
        let inner = bounds.insetBy(dx: edgeMargin, dy: 4)
        guard inner.width >= size.width else { return nil }

        let centeredX = min(max(highlight.midX - size.width / 2, inner.minX), inner.maxX - size.width)
        let candidates = [
            AnchoredPlacement(frame: CGRect(x: centeredX, y: highlight.minY - gap - size.height, width: size.width, height: size.height), side: .above),
            AnchoredPlacement(frame: CGRect(x: centeredX, y: highlight.maxY + gap, width: size.width, height: size.height), side: .below),
            AnchoredPlacement(frame: CGRect(x: highlight.maxX + gap, y: highlight.midY - size.height / 2, width: size.width, height: size.height), side: .right),
        ]
        func fits(_ p: AnchoredPlacement) -> Bool {
            inner.contains(p.frame)
        }
        func isFree(_ p: AnchoredPlacement) -> Bool {
            !occupied.contains { $0.intersects(p.frame) }
        }
        func connectorOK(_ p: AnchoredPlacement) -> Bool {
            BubbleConnector.length(bubble: p.frame, highlight: highlight, side: p.side) <= maxConnectorLength
        }

        guard let base = candidates.first(where: fits) else { return nil }
        if isFree(base) { return base }

        let overlapping = occupied.filter { $0.intersects(base.frame) }
        let leftShift = overlapping.map { base.frame.maxX - $0.minX }.max()! + edgeMargin
        let rightShift = overlapping.map { $0.maxX - base.frame.minX }.max()! + edgeMargin
        var attempts: [AnchoredPlacement] = []
        if base.side == .above { attempts.append(candidates[1]) }
        attempts.append(AnchoredPlacement(frame: base.frame.offsetBy(dx: -leftShift, dy: 0), side: base.side))
        attempts.append(AnchoredPlacement(frame: base.frame.offsetBy(dx: rightShift, dy: 0), side: base.side))
        return attempts.first { fits($0) && isFree($0) && connectorOK($0) }
    }
}
