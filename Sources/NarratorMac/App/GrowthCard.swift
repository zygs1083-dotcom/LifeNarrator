import NarratorBrain
import SwiftUI

struct GrowthCard: View {
    @ObservedObject var store: AppStore
    private let hue = AppTheme.hue(320)

    var body: some View {
        GroupBox {
            if let growth = store.growthState {
                HStack(spacing: 10) {
                    IconChip(symbol: "text.bubble.fill", hue: hue)
                    Text(verbatim: store.spriteDisplayName).font(AppTheme.font(.cardTitle))
                    Badge(text: "Lv.\(growth.level)", hue: hue)
                    Text(verbatim: growth.title(lang: store.settings.language.lang))
                        .font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                }
                GrowthExperienceView(growth: growth, language: store.settings.language)
                if let next = growth.nextUnlock {
                    Text(String(format: store.text("growth.nextUnlock"), next.level, next.name(lang: store.settings.language.lang)))
                        .font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
                }
                HStack(spacing: 24) {
                    statistic("growth.daysKnown", growth.daysKnown(now: Date()))
                    statistic("growth.streak", growth.consecutiveDays)
                    statistic("growth.narrations", growth.narrations)
                    statistic("growth.chats", growth.chatMessages)
                }.padding(.vertical, 4)
                LabeledContent(store.text("growth.name")) {
                    TextField(store.text("tab.sprite"), text: $store.settings.spriteName)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                        .disabled(!store.isUnlocked(.spriteName))
                }
                if !store.isUnlocked(.spriteName) { UnlockLabel(store: store, unlock: .spriteName) }
            }
        } label: { CardHeading(title: store.text("growth.title"), symbol: "leaf.fill", hue: hue) }
    }

    private func statistic(_ key: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value, format: .number).font(AppTheme.font(.badge)).monospacedDigit()
            Text(store.text(key)).font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
        }
    }
}

struct GrowthExperienceView: View {
    let growth: GrowthState
    let language: InterfaceLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: progress)
                .tint(AppTheme.accent)
                .accessibilityLabel(AppLocalization.string("growth.experience", language: language))
                .accessibilityValue(experience)
            Text(verbatim: experience).font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var progress: Double {
        guard let next = growth.nextLevelExperience else { return 1 }
        let start = growth.level == 1 ? 0 : 40 * growth.level * growth.level
        return Double(growth.experience - start) / Double(next - start)
    }

    private var experience: String {
        if let next = growth.nextLevelExperience { return "\(growth.experience) / \(next) XP" }
        return "\(growth.experience) XP · \(AppLocalization.string("growth.maxLevel", language: language))"
    }
}

struct UnlockLabel: View {
    @ObservedObject var store: AppStore
    let unlock: GrowthUnlock

    var body: some View {
        Label(String(format: store.text("growth.locked"), unlock.level, unlock.name(lang: store.settings.language.lang)), systemImage: "lock.fill")
            .font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
    }
}
