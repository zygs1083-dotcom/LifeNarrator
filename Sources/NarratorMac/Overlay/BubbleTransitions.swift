import SwiftUI

/// Bubble entrance/exit pairs and the sprite's frame-first entrance.
enum BubbleTransitions {
    static func bubble(_ animation: BubbleAnimation, anchor: UnitPoint, slide: CGSize, delay: Double, reduceMotion: Bool = false) -> AnyTransition {
        if reduceMotion {
            return .asymmetric(
                insertion: .opacity.animation(.easeOut(duration: 0.18).delay(delay)),
                removal: .opacity.animation(.easeIn(duration: 0.6)))
        }
        return switch animation {
        case .fade:
            .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: anchor)).animation(.easeOut(duration: 0.18).delay(delay)),
                removal: .opacity.animation(.easeIn(duration: 0.6)))
        case .bounce:
            .asymmetric(
                insertion: AnyTransition.scale(scale: 0.3, anchor: anchor).animation(.spring(response: 0.42, dampingFraction: 0.55).delay(delay))
                    .combined(with: .opacity.animation(.easeOut(duration: 0.1).delay(delay))),
                removal: AnyTransition.scale(scale: 0.6, anchor: anchor).combined(with: .opacity).animation(.easeIn(duration: 0.16)))
        case .slide:
            .asymmetric(
                insertion: AnyTransition.offset(slide).combined(with: .opacity).animation(.spring(response: 0.35, dampingFraction: 0.8).delay(delay)),
                removal: AnyTransition.offset(slide).combined(with: .opacity).animation(.easeIn(duration: 0.2)))
        case .pop:
            .asymmetric(
                insertion: AnyTransition.scale(scale: 0.5, anchor: anchor).combined(with: .opacity).animation(.spring(response: 0.30, dampingFraction: 0.70).delay(delay)),
                removal: AnyTransition.scale(scale: 0.9, anchor: anchor).combined(with: .opacity).animation(.easeIn(duration: 0.15)))
        }
    }

    static func decor() -> AnyTransition {
        .asymmetric(insertion: .identity, removal: .opacity.animation(.easeIn(duration: 0.6)))
    }

    /// How long after the delay the entrance has settled; the dwell timer starts then.
    static func entranceDuration(_ animation: BubbleAnimation) -> Double {
        switch animation {
        case .fade: 0.18
        case .bounce: 0.6
        case .slide: 0.45
        case .pop: 0.4
        }
    }
}

struct SpriteDecorEntrance: View {
    let decor: AnchorDecor
    let delay: Double
    let reduceMotion: Bool
    @State private var entered = false

    var body: some View {
        AnchorDecorView(decor: decor, progress: reduceMotion || entered ? 1 : 0)
            .opacity(reduceMotion && !entered ? 0 : 1)
            .animation(.easeOut(duration: reduceMotion ? 0.18 : 0.24).delay(delay), value: entered)
            .onAppear { entered = true }
    }
}
