import AppKit
import NarratorCore
import SwiftUI

extension Color {
    init(_ c: PaletteColor) {
        self.init(red: c.red, green: c.green, blue: c.blue)
    }
}

/// Everything needed to draw one bubble, independent of where it sits on screen.
struct BubbleAppearance {
    var shape: BubbleShape
    var size: BubbleSize
    var theme: ColorTheme
    var group: ColorGroup
    var effects: TextEffects
    var font: Font
    var text: String
    var emoji: [String]
    var rotation: Angle
    /// Measured text + emoji + padding box (visual-spec §1).
    var contentSize: CGSize
    /// Speech only, in body-local coordinates.
    var tail: SpeechTail?
    /// Speech only: room reserved under the body for an app-level tail so stacked bubbles don't overlap it.
    var tailBelowBody: CGFloat

    var neon: Bool { theme == .neon }

    /// Builds the appearance and measures the content box with the real SwiftUI layout.
    @MainActor
    static func make(shape: BubbleShape, size: BubbleSize, theme: ColorTheme, group: ColorGroup, effects: TextEffects, font: Font, text: String, emoji: [String], quipID: String) -> BubbleAppearance {
        let rotation: Angle = switch shape {
        case .sticker: .degrees(stickerAngle(quipID: quipID))
        case .note: .degrees(noteAngle(quipID: quipID))
        default: .zero
        }
        var a = BubbleAppearance(shape: shape, size: size, theme: theme, group: group, effects: effects, font: font, text: text, emoji: emoji, rotation: rotation, contentSize: .zero, tail: nil, tailBelowBody: 0)
        let measured = NSHostingController(rootView: BubbleContentView(appearance: a))
            .sizeThatFits(in: CGSize(width: size.maxWidth, height: 10_000))
        a.contentSize = CGSize(width: (measured.width * 2).rounded(.up) / 2, height: (measured.height * 2).rounded(.up) / 2)
        return a
    }

    /// Outer box handed to placement (§2 per-shape expansion).
    var outerSize: CGSize {
        switch shape {
        case .text, .rounded:
            contentSize
        case .cloud:
            CGSize(width: contentSize.width + 0.5 * contentSize.height, height: 1.9 * contentSize.height)
        case .speech:
            CGSize(width: contentSize.width, height: contentSize.height + tailBelowBody)
        case .sticker:
            CGSize(width: contentSize.width + 2 * size.stickerPaperInset, height: contentSize.height + 2 * size.stickerPaperInset)
        case .note:
            CGSize(width: max(contentSize.width, 2.2 * (size.fontSize + size.lineSpacing)), height: contentSize.height + 8)
        }
    }

    var contentOrigin: CGPoint {
        switch shape {
        case .text, .rounded, .speech: .zero
        case .cloud: CGPoint(x: 0.25 * contentSize.height, y: 0.45 * contentSize.height)
        case .sticker: CGPoint(x: size.stickerPaperInset, y: size.stickerPaperInset)
        case .note: CGPoint(x: (outerSize.width - contentSize.width) / 2, y: 8)
        }
    }

    /// The rect the shape itself occupies inside the outer box.
    var bodyRect: CGRect {
        switch shape {
        case .text, .rounded, .speech: CGRect(origin: .zero, size: contentSize)
        case .cloud, .sticker, .note: CGRect(origin: .zero, size: outerSize)
        }
    }

    /// §2.3 anchored tail: tip 2pt short of the highlight edge, root following the highlight center. Frames are in the same space.
    mutating func setAnchoredTail(frame: CGRect, highlight: CGRect, side: AnchorSide) {
        let tip = BubbleConnector.speechTailTip(bubble: frame, highlight: highlight, side: side)
        let root = BubbleConnector.speechTailRoot(bubble: frame, highlight: highlight, side: side, cornerRadius: size.speechCornerRadius, tailBase: size.speechTailBase)
        let (edge, localRoot): (SpeechTail.Edge, CGFloat) = switch side {
        case .above: (.bottom, root - frame.minX)
        case .below: (.top, root - frame.minX)
        case .right: (.left, root - frame.minY)
        }
        tail = SpeechTail(edge: edge, root: localRoot, tip: CGPoint(x: tip.x - frame.minX, y: tip.y - frame.minY), base: size.speechTailBase)
    }

    /// §2.3 app-level tail on the bottom edge, 25% in from the window-side end, tip nudged 6pt toward the window center.
    mutating func setAppLevelTail(corner: WindowCorner) {
        let root = corner == .topRight ? 0.75 * contentSize.width : 0.25 * contentSize.width
        let tipX = corner == .topRight ? root - 6 : root + 6
        tail = SpeechTail(edge: .bottom, root: root, tip: CGPoint(x: tipX, y: contentSize.height + size.speechTailHeight), base: size.speechTailBase)
    }

    /// §6 transform anchor: tail tip for speech, else the edge/corner facing the anchor.
    func scaleAnchor(side: AnchorSide?, corner: WindowCorner) -> UnitPoint {
        if let tail {
            return UnitPoint(x: tail.tip.x / outerSize.width, y: tail.tip.y / outerSize.height)
        }
        return switch side {
        case .above: UnitPoint(x: 0.5, y: 1)
        case .below: UnitPoint(x: 0.5, y: 0)
        case .right: UnitPoint(x: 0, y: 0.5)
        case nil: corner == .topRight ? .topTrailing : .topLeading
        }
    }
}

/// Text followed by the emoji, with the §1 padding (note adds +2 / +4).
struct BubbleContentView: View {
    let appearance: BubbleAppearance

    var body: some View {
        let size = appearance.size
        let extra: CGSize = appearance.shape == .note ? CGSize(width: 2, height: 4) : .zero
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            ArtText(appearance: appearance)
            if !appearance.emoji.isEmpty {
                Text(appearance.emoji.joined())
                    .font(.system(size: size.emojiSize))
            }
        }
        .padding(.horizontal, size.horizontalPadding + extra.width)
        .padding(.vertical, size.verticalPadding + extra.height)
    }
}

/// §4 art text: shadow under 8 outline copies under the body (solid or gradient). Emoji are not part of this.
struct ArtText: View {
    let appearance: BubbleAppearance

    private var base: some View {
        Text(appearance.text)
            .font(appearance.font)
            .lineSpacing(appearance.size.lineSpacing)
            .lineLimit(appearance.size.maxLines)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
    }

    var body: some View {
        let fs = appearance.size.fontSize
        let neon = appearance.neon
        // With no bubble behind it, light text on a dark edge reads on both light and dark windows.
        let textOnly = appearance.shape == .text && !neon
        let text = textOnly ? appearance.group.fill : appearance.group.text
        let w = max(1, 0.07 * fs)
        let outlineColor = neon ? Color(PaletteColor(hex: ColorTheme.neonFill)) : Color(textOnly ? appearance.group.text : appearance.group.stroke)
        let offsets: [CGPoint] = [
            CGPoint(x: w, y: 0), CGPoint(x: -w, y: 0), CGPoint(x: 0, y: w), CGPoint(x: 0, y: -w),
            CGPoint(x: 0.71 * w, y: 0.71 * w), CGPoint(x: -0.71 * w, y: 0.71 * w),
            CGPoint(x: 0.71 * w, y: -0.71 * w), CGPoint(x: -0.71 * w, y: -0.71 * w),
        ]
        let gradientTop = neon ? text : text.mixedWithWhite(0.35)
        let gradientBottom = neon ? text.mixedWithWhite(0.40) : text
        ZStack {
            if appearance.effects.contains(.outline) {
                ForEach(0..<8, id: \.self) { i in
                    base.foregroundStyle(outlineColor).offset(x: offsets[i].x, y: offsets[i].y)
                }
            }
            if appearance.effects.contains(.gradient) {
                base.foregroundStyle(LinearGradient(colors: [Color(gradientTop), Color(gradientBottom)], startPoint: .top, endPoint: .bottom))
            } else {
                base.foregroundStyle(Color(text))
            }
        }
        .shadow(color: neon ? Color(text).opacity(0.8) : .clear, radius: neon ? 0.35 * fs : 0)
        .shadow(color: appearance.effects.contains(.shadow) ? .black.opacity(neon ? 0.45 : 0.25) : .clear, radius: 0, x: 0.06 * fs, y: 0.10 * fs)
        .shadow(color: textOnly ? .black.opacity(0.35) : .clear, radius: 2)
    }
}

/// Shape plus content, sized to `appearance.outerSize`. A speech tail may extend outside that box.
struct BubbleBodyView: View {
    let appearance: BubbleAppearance

    var body: some View {
        let a = appearance
        let outer = a.outerSize
        let body = a.bodyRect
        ZStack(alignment: .topLeading) {
            shapeLayer
                .frame(width: body.width, height: body.height)
                .offset(x: body.minX, y: body.minY)
            BubbleContentView(appearance: a)
                .frame(width: a.contentSize.width, height: a.contentSize.height)
                .offset(x: a.contentOrigin.x, y: a.contentOrigin.y)
        }
        .frame(width: outer.width, height: outer.height, alignment: .topLeading)
        .rotationEffect(a.rotation)
        .overlay(alignment: .topLeading) {
            if a.shape == .note {
                // Tape is drawn after the note's tilt and keeps its own fixed −6°.
                Rectangle()
                    .fill(.white.opacity(0.55))
                    .frame(width: a.size.noteTapeSize.width, height: a.size.noteTapeSize.height)
                    .rotationEffect(.degrees(-6))
                    .position(x: outer.width / 2, y: -3)
            }
        }
    }

    @ViewBuilder
    private var shapeLayer: some View {
        let a = appearance
        let fill = Color(a.group.fill)
        let stroke = Color(a.group.stroke)
        let glow = a.neon ? stroke.opacity(0.7) : .clear
        let glowRadius: CGFloat = a.neon ? 8 : 0
        switch a.shape {
        case .text:
            EmptyView()
        case .rounded:
            let shape = RoundedRectangle(cornerRadius: min(a.contentSize.height / 2, a.size.roundedCornerRadius), style: .continuous)
            shape.fill(fill)
                .overlay(shape.stroke(stroke, lineWidth: a.size.strokeWidth).shadow(color: glow, radius: glowRadius))
                .compositingGroup()
                .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 3)
        case .speech:
            let shape = SpeechShape(cornerRadius: a.size.speechCornerRadius, tail: a.tail)
            shape.fill(fill)
                .overlay(shape.stroke(stroke, lineWidth: a.size.strokeWidth).shadow(color: glow, radius: glowRadius))
                .compositingGroup()
                .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 3)
        case .cloud:
            // Stroke at double width first, then fill on top: only the outer outline survives.
            ZStack {
                CloudShape().stroke(stroke, lineWidth: 2 * a.size.strokeWidth).shadow(color: glow, radius: glowRadius)
                CloudShape().fill(fill)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 3)
        case .sticker:
            let inset = a.size.stickerPaperInset
            let paper = RoundedRectangle(cornerRadius: a.size.stickerCornerRadius + inset, style: .continuous)
            paper.fill(.white)
                .overlay(paper.stroke(stroke, lineWidth: 1.5).shadow(color: glow, radius: glowRadius))
                .compositingGroup()
                .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 3)
                .overlay {
                    RoundedRectangle(cornerRadius: a.size.stickerCornerRadius, style: .continuous)
                        .fill(fill)
                        .padding(inset)
                }
        case .note:
            RoundedRectangle(cornerRadius: 2)
                .fill(fill)
                .shadow(color: .black.opacity(0.20), radius: 4, x: 0, y: 2)
        }
    }
}
