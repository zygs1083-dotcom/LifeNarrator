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
    case above, below, right
}

public struct AnchoredPlacement: Sendable, Equatable {
    public let frame: CGRect
    public let side: AnchorSide

    public init(frame: CGRect, side: AnchorSide) {
        self.frame = frame
        self.side = side
    }
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
