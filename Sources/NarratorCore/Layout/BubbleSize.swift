import Foundation

/// Size tier from visual-spec §1, plus the per-tier shape constants of §2 and §7.
public enum BubbleSize: String, CaseIterable, Sendable {
    case small, medium, large

    public var fontSize: CGFloat { pick(14, 18, 24) }
    public var lineSpacing: CGFloat { pick(2, 3, 4) }
    public var maxWidth: CGFloat { pick(220, 300, 400) }
    public var maxLines: Int { Int(pick(2, 3, 3)) }
    public var horizontalPadding: CGFloat { pick(10, 14, 18) }
    public var verticalPadding: CGFloat { pick(6, 9, 12) }
    public var emojiSize: CGFloat { pick(16, 20, 26) }
    public var strokeWidth: CGFloat { pick(1.5, 2, 2.5) }

    public var roundedCornerRadius: CGFloat { pick(16, 20, 26) }
    public var speechCornerRadius: CGFloat { pick(12, 14, 18) }
    public var speechTailBase: CGFloat { pick(14, 18, 22) }
    public var speechTailHeight: CGFloat { pick(12, 16, 20) }
    public var stickerCornerRadius: CGFloat { pick(8, 10, 12) }
    public var stickerPaperInset: CGFloat { pick(4, 5, 6) }
    public var noteTapeSize: CGSize { CGSize(width: pick(30, 36, 44), height: pick(10, 12, 14)) }
    public var highlightStrokeWidth: CGFloat { pick(2, 2.5, 3) }

    /// Next tier down for the §8.3 downgrade rule; nil at S.
    public var smaller: BubbleSize? {
        switch self {
        case .large: .medium
        case .medium: .small
        case .small: nil
        }
    }

    private func pick(_ s: CGFloat, _ m: CGFloat, _ l: CGFloat) -> CGFloat {
        switch self {
        case .small: s
        case .medium: m
        case .large: l
        }
    }
}
