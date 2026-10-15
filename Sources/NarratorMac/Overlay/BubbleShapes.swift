import SwiftUI

struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            for index in 0..<10 {
                let angle = Double(index) * .pi / 5 - .pi / 2
                let radius = index.isMultiple(of: 2) ? 1.0 : 0.62
                let point = CGPoint(x: rect.midX + cos(angle) * radius * rect.width / 2,
                                    y: rect.midY + sin(angle) * radius * rect.height / 2)
                if index == 0 { path.move(to: point) }
                else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
    }
}

/// Tail of a speech bubble in the body's local coordinates (visual-spec §2.3).
struct SpeechTail: Equatable {
    enum Edge { case top, bottom, left, right }

    var edge: Edge
    /// Root center along the edge: x for top/bottom, y for left.
    var root: CGFloat
    var tip: CGPoint
    var base: CGFloat
}

/// Rounded rect traced clockwise (in SwiftUI's y-down space) so every sub-path of a union shares a winding direction.
private func addClockwiseRoundedRect(_ p: inout Path, in rect: CGRect, radius r: CGFloat) {
    p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
    p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
    p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
    p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
    p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r)
    p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
    p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + r, y: rect.minY), radius: r)
    p.closeSubpath()
}

/// §2.3: rounded body with the tail spliced into one edge so the stroke is continuous.
struct SpeechShape: Shape {
    var cornerRadius: CGFloat
    var tail: SpeechTail?

    func path(in rect: CGRect) -> Path {
        let r = cornerRadius
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        if let t = tail, t.edge == .top {
            addTail(&p, t, from: CGPoint(x: rect.minX + t.root - t.base / 2, y: rect.minY), to: CGPoint(x: rect.minX + t.root + t.base / 2, y: rect.minY))
        }
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)
        if let t = tail, t.edge == .right {
            addTail(&p, t, from: CGPoint(x: rect.maxX, y: rect.minY + t.root - t.base / 2), to: CGPoint(x: rect.maxX, y: rect.minY + t.root + t.base / 2))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
        if let t = tail, t.edge == .bottom {
            addTail(&p, t, from: CGPoint(x: rect.minX + t.root + t.base / 2, y: rect.maxY), to: CGPoint(x: rect.minX + t.root - t.base / 2, y: rect.maxY))
        }
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r)
        if let t = tail, t.edge == .left {
            addTail(&p, t, from: CGPoint(x: rect.minX, y: rect.minY + t.root + t.base / 2), to: CGPoint(x: rect.minX, y: rect.minY + t.root - t.base / 2))
        }
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + r, y: rect.minY), radius: r)
        p.closeSubpath()
        return p
    }

    private func addTail(_ p: inout Path, _ t: SpeechTail, from p1: CGPoint, to p2: CGPoint) {
        // Control points sit 25% of the base width toward the tail's own axis.
        let inward = CGPoint(x: (p2.x - p1.x) * 0.25, y: (p2.y - p1.y) * 0.25)
        p.addLine(to: p1)
        p.addQuadCurve(to: t.tip, control: CGPoint(x: (p1.x + t.tip.x) / 2 + inward.x, y: (p1.y + t.tip.y) / 2 + inward.y))
        p.addQuadCurve(to: p2, control: CGPoint(x: (t.tip.x + p2.x) / 2 - inward.x, y: (t.tip.y + p2.y) / 2 - inward.y))
    }
}

/// §2.2: core rounded rect plus a ring of bumps, all one non-zero-winding path. `rect` is the expanded W′ × H′ box.
struct CloudShape: Shape {
    func path(in rect: CGRect) -> Path {
        let h = rect.height
        let w = rect.width
        var p = Path()
        addClockwiseRoundedRect(&p, in: CGRect(x: rect.minX + 0.15 * h, y: rect.minY + 0.15 * h, width: w - 0.3 * h, height: h - 0.3 * h), radius: 0.35 * h)

        func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
            addClockwiseRoundedRect(&p, in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), radius: r)
        }

        let n = max(3, Int((w / (0.5 * h)).rounded()))
        let firstX = rect.minX + 0.2 * h
        let stepX = (w - 0.4 * h) / CGFloat(n - 1)
        let topXs = (0..<n).map { firstX + stepX * CGFloat($0) }
        for (i, x) in topXs.enumerated() {
            circle(x, rect.minY + 0.3 * h, i.isMultiple(of: 2) ? 0.36 * h : 0.30 * h)
        }
        for i in 0..<(n - 1) {
            circle((topXs[i] + topXs[i + 1]) / 2, rect.minY + 0.72 * h, 0.27 * h)
        }
        circle(rect.minX + 0.18 * h, rect.minY + 0.5 * h, 0.3 * h)
        circle(rect.maxX - 0.18 * h, rect.minY + 0.5 * h, 0.3 * h)
        return p
    }
}
