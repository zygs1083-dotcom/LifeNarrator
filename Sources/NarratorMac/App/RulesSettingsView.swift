import NarratorCore
import SwiftUI

struct RulesSettingsView: View {
    @ObservedObject var store: AppStore
    @State private var expanded: Bool
    private let hue = AppTheme.hue(150)

    init(store: AppStore, expanded: Bool = false) {
        self.store = store
        _expanded = State(initialValue: expanded)
    }

    var builtinEnabled: Binding<Bool> {
        Binding(get: {
            !store.builtin.rules.allSatisfy { store.settings.disabledBuiltinIds.contains($0.id) }
        }, set: {
            store.settings.disabledBuiltinIds = $0 ? [] : Set(store.builtin.rules.map(\.id))
        })
    }

    func builtinRuleEnabled(_ id: String) -> Binding<Bool> {
        Binding(get: { !store.settings.disabledBuiltinIds.contains(id) }, set: {
            if $0 { store.settings.disabledBuiltinIds.remove(id) }
            else { store.settings.disabledBuiltinIds.insert(id) }
        })
    }

    var body: some View {
        VStack(spacing: 14) {
            GroupBox {
                if store.rules.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "text.bubble.fill")
                            .font(.system(size: 44)).foregroundStyle(AppTheme.accentSoft)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "sparkles").font(.system(size: 18)).foregroundStyle(AppTheme.accent)
                            }.accessibilityHidden(true)
                        Text(store.text("rules.empty.title")).font(AppTheme.font(.cardTitle))
                        Text(store.text("rules.empty.body"))
                            .font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.center).frame(maxWidth: 430)
                        Button(store.text("rules.empty.action")) { store.showInput() }
                            .buttonStyle(AppTheme.CapsuleButton())
                    }.frame(maxWidth: .infinity).padding(.vertical, 16)
                } else {
                    ForEach(store.rules, id: \.id) { rule in
                        if rule.id != store.rules.first!.id { Rectangle().fill(AppTheme.cardStroke).frame(height: 1) }
                        HStack(spacing: 10) {
                            IconChip(symbol: symbol(rule.kind), hue: ruleHue(rule.kind))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: rule.label[store.settings.language.lang])
                                if let input = rule.input {
                                    Text(verbatim: input).font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
                                }
                            }
                            Spacer()
                            Text(store.text("kind.\(rule.kind.rawValue)"))
                                .font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
                            Toggle(rule.label[store.settings.language.lang], isOn: Binding(get: { rule.enabled }, set: { enabled in
                                store.perform { try store.setEnabled(enabled, id: rule.id) }
                            })).labelsHidden()
                            Button { store.perform { try store.deleteRule(id: rule.id) } } label: {
                                Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                            }.buttonStyle(.plain).help(store.text("delete")).accessibilityLabel(store.text("delete"))
                        }.padding(.vertical, 8)
                    }
                }
            } label: {
                HStack {
                    CardHeading(title: store.text("rules.user"), symbol: "text.badge.checkmark", hue: hue)
                    Spacer()
                    Badge(text: count(store.rules.count), hue: hue)
                }
            }
            GroupBox {
                Text(store.text("rules.builtin.hint")).font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
                DisclosureGroup(store.text("rules.builtin.show"), isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach([RuleKind.app, .site, .time], id: \.self) { kind in
                            let rules = store.builtin.rules.filter { $0.kind == kind }
                            HStack {
                                Text(store.text("kind.\(kind.rawValue)"))
                                Badge(text: count(rules.count), hue: hue)
                            }.padding(.top, 8)
                            ForEach(rules, id: \.id) { rule in
                                LabeledContent(rule.label[store.settings.language.lang]) {
                                    Toggle(rule.label[store.settings.language.lang], isOn: builtinRuleEnabled(rule.id))
                                        .labelsHidden().disabled(!builtinEnabled.wrappedValue)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }.frame(minHeight: 28)
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    CardHeading(title: store.text("rules.builtin"), symbol: "shippingbox.fill", hue: hue)
                    Spacer()
                    Badge(text: count(store.builtin.rules.count), hue: hue)
                    Toggle(store.text("rules.builtin"), isOn: builtinEnabled).labelsHidden()
                }
            }
        }
    }

    private func count(_ value: Int) -> String { String(format: store.text("format.count"), value) }
    private func symbol(_ kind: RuleKind) -> String {
        switch kind {
        case .app: "macwindow"
        case .site: "globe"
        case .person: "person.fill"
        case .topic: "tag.fill"
        case .time: "clock.fill"
        }
    }
    private func ruleHue(_ kind: RuleKind) -> AppTheme.Hue {
        switch kind {
        case .app: AppTheme.hue(200)
        case .site: AppTheme.hue(222)
        case .person: AppTheme.hue(320)
        case .topic: AppTheme.hue(42)
        case .time: AppTheme.hue(255)
        }
    }
}
