import NarratorCore
import SwiftUI

/// Sprite frame plus its connection to the bubble, in the overlay's coordinates.
struct AnchorDecor {
    var highlight: CGRect
    var bubbleFrame: CGRect
    var side: AnchorSide
    var shape: BubbleShape
    var size: BubbleSize
    var group: ColorGroup
    var connector: Bool = true
    var outside: Bool = false
    var framed: Bool = true
}

struct AnchorDecorView: View {
    let decor: AnchorDecor
    var progress: CGFloat = 1

    var body: some View {
        let d = decor
        let stroke = Color(d.group.stroke)
        let box = Path { p in
            let r = d.highlight
            p.move(to: CGPoint(x: r.minX + 5, y: r.minY))
            p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: 5)
            p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: 5)
            p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: 5)
            p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: 5)
            p.closeSubpath()
        }
        let lineWidth: CGFloat = switch d.size {
        case .small: 1.5
        case .medium: 2
        case .large: 2.5
        }
        let gap: CGFloat = switch d.side {
        case .above: d.highlight.minY - d.bubbleFrame.maxY
        case .below: d.bubbleFrame.minY - d.highlight.maxY
        case .right: d.bubbleFrame.minX - d.highlight.maxX
        case .left: d.highlight.minX - d.bubbleFrame.maxX
        }
        ZStack(alignment: .topLeading) {
            if d.framed {
                ZStack {
                    box.fill(stroke.opacity(0.08 * progress))
                    box.trim(from: 0, to: progress)
                        .stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    box.trim(from: 0, to: progress)
                        .stroke(stroke, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                }
                .compositingGroup()
                .shadow(color: .black.opacity(0.3), radius: 1.5)
            }
            if d.connector {
                if d.outside {
                    let endpoints = BubbleConnector.endpoints(bubble: d.bubbleFrame, highlight: d.highlight, side: d.side)
                    Path { p in
                        p.move(to: endpoints.bubble)
                        p.addLine(to: endpoints.highlight)
                    }
                    .stroke(stroke, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                } else {
                    switch d.shape {
                    case .speech:
                        EmptyView()
                    case .cloud:
                        let dots = BubbleConnector.thoughtDots(bubble: d.bubbleFrame, highlight: d.highlight, side: d.side, cloudHeight: d.bubbleFrame.height)
                        ForEach(0..<3, id: \.self) { i in
                            let dot = dots[i]
                            let circle = Path(ellipseIn: CGRect(x: dot.center.x - dot.radius, y: dot.center.y - dot.radius, width: 2 * dot.radius, height: 2 * dot.radius))
                            circle.fill(Color(d.group.fill))
                            circle.stroke(stroke, lineWidth: d.size.strokeWidth)
                        }
                    case .text, .rounded, .sticker, .note, .star:
                        if gap > 12, let line = BubbleConnector.line(bubble: d.bubbleFrame, highlight: d.highlight, side: d.side) {
                            Path { p in
                                p.move(to: line.from)
                                p.addLine(to: line.to)
                            }
                            .stroke(stroke, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        }
                    }
                }
            }
        }
    }
}
