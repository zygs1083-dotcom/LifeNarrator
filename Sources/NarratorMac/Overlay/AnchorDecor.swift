import NarratorCore
import SwiftUI

/// Highlight box plus its connection to the bubble (visual-spec §7), in the overlay's coordinates.
struct AnchorDecor {
    var highlight: CGRect
    var bubbleFrame: CGRect
    var side: AnchorSide
    var shape: BubbleShape
    var size: BubbleSize
    var group: ColorGroup
}

struct AnchorDecorView: View {
    let decor: AnchorDecor

    var body: some View {
        let d = decor
        let stroke = Color(d.group.stroke)
        let box = Path { $0.addRoundedRect(in: d.highlight, cornerSize: CGSize(width: 6, height: 6)) }
        ZStack(alignment: .topLeading) {
            box.fill(stroke.opacity(0.12))
            box.stroke(stroke, style: StrokeStyle(lineWidth: d.size.highlightStrokeWidth, lineCap: .round))
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
            case .rounded, .sticker, .note:
                if let line = BubbleConnector.line(bubble: d.bubbleFrame, highlight: d.highlight, side: d.side) {
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
