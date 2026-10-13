import AppKit
import SwiftUI

@MainActor
enum AppTheme {
    static let windowBackground = color(0xFFF9F6, 0x1C171B)
    static let card = color(0xFFFFFF, 0x262026)
    static let cardStroke = color(0xF4E6E1, 0x362D35)
    static let textPrimary = color(0x2B2226, 0xF4ECF1)
    static let textSecondary = color(0x6F5F66, 0xA89AA3)
    static let accent = color(0xF55DC2, 0xF55DC2)
    static let accentSoft = hue(320).soft
    static let accentText = hue(320).text
    static let accentDeep = color(0xB22483, 0xFFB2E6)

    struct Hue {
        let soft: Color
        let text: Color
        let stroke: Color
    }

    static func hue(_ degrees: Double) -> Hue {
        let h = degrees / 360
        return Hue(
            soft: dynamic { dark in NSColor(calibratedHue: h, saturation: dark ? 0.42 : 0.22, brightness: dark ? 0.34 : 1, alpha: 1) },
            text: dynamic { dark in NSColor(calibratedHue: h, saturation: dark ? 0.30 : 0.78, brightness: dark ? 1 : 0.40, alpha: 1) },
            stroke: dynamic { _ in NSColor(calibratedHue: h, saturation: 0.62, brightness: 0.96, alpha: 1) })
    }

    enum FontRole { case hero, pageTitle, cardTitle, body, caption, badge, input, emoji }

    static func font(_ role: FontRole) -> Font {
        let size: CGFloat
        let weight: Font.Weight
        switch role {
        case .hero: (size, weight) = (26, .bold)
        case .pageTitle: (size, weight) = (20, .semibold)
        case .cardTitle: (size, weight) = (15, .semibold)
        case .body: (size, weight) = (13, .regular)
        case .caption: (size, weight) = (11, .regular)
        case .badge: (size, weight) = (12, .semibold)
        case .input: (size, weight) = (20, .regular)
        case .emoji: (size, weight) = (22, .regular)
        }
        if (role == .hero || role == .cardTitle), NSFontManager.shared.availableFontFamilies.contains("Yuanti SC") {
            return .custom("YuantiSC-Regular", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .rounded)
    }

    private static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        dynamic { isDark in
            let hex = isDark ? dark : light
            return NSColor(calibratedRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
        }
    }

    private static func dynamic(_ resolve: @escaping @Sendable (Bool) -> NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            resolve(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        })
    }

    struct CardStyle: GroupBoxStyle {
        @Environment(\.colorScheme) private var colorScheme
        func makeBody(configuration: Configuration) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                configuration.label
                VStack(alignment: .leading, spacing: 10) { configuration.content }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.06), radius: 10, y: 3)
        }
    }

    struct CapsuleButton: ButtonStyle {
        var hue: Hue = AppTheme.hue(320)
        var filled = true
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(filled ? hue.text : AppTheme.textPrimary)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background {
                    Capsule().fill(filled ? hue.soft : Color.clear)
                    Capsule().fill(hue.stroke.opacity(configuration.isPressed ? 0.15 : 0))
                }
                .overlay(Capsule().stroke(filled ? hue.stroke : AppTheme.cardStroke, lineWidth: 1))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

extension GroupBoxStyle where Self == AppTheme.CardStyle {
    static var card: AppTheme.CardStyle { AppTheme.CardStyle() }
}

struct Badge: View {
    let text: String
    let hue: AppTheme.Hue
    var body: some View {
        Text(verbatim: text).font(AppTheme.font(.badge)).monospacedDigit()
            .foregroundStyle(hue.text).padding(.horizontal, 8).padding(.vertical, 3)
            .background(hue.soft, in: Capsule())
    }
}

struct IconChip: View {
    let symbol: String
    let hue: AppTheme.Hue
    var body: some View {
        Image(systemName: symbol).font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(hue.text).frame(width: 26, height: 26)
            .background(hue.soft, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

struct CardHeading: View {
    let title: String
    let symbol: String
    let hue: AppTheme.Hue
    var caption: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                IconChip(symbol: symbol, hue: hue)
                Text(verbatim: title).font(AppTheme.font(.cardTitle)).foregroundStyle(AppTheme.textPrimary)
            }
            if let caption {
                Text(verbatim: caption).font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
            }
        }
    }
}

struct ChoiceCards<T: Hashable>: View {
    let options: [(value: T, emoji: String, title: String, caption: String)]
    @Binding var selection: T
    let hue: AppTheme.Hue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(options, id: \.value) { option in
                let selected = selection == option.value
                Button { selection = option.value } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: option.emoji).font(AppTheme.font(.emoji)).accessibilityHidden(true)
                        Text(verbatim: option.title).font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text(verbatim: option.caption).font(AppTheme.font(.caption))
                            .foregroundStyle(selected ? hue.text : AppTheme.textSecondary)
                    }
                    .foregroundStyle(selected ? hue.text : AppTheme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading).padding(12)
                    .background(selected ? hue.soft : AppTheme.card, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? hue.stroke : AppTheme.cardStroke, lineWidth: selected ? 1.5 : 1))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: selection)
    }
}

struct SliderRow: View {
    let title: String
    var hint: String? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Int) -> String
    let hue: AppTheme.Hue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: title)
                Spacer()
                Badge(text: format(Int(value)), hue: hue)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: value)
            }.frame(minHeight: 28)
            Slider(value: $value, in: range, step: 1).tint(AppTheme.accent)
                .accessibilityLabel(title).accessibilityValue(format(Int(value)))
            if let hint {
                Text(verbatim: hint).font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
            }
        }
    }
}
