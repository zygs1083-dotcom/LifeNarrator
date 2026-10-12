import KeyboardShortcuts
import NarratorCore
import SwiftUI

public struct AppSettingsView: View {
    @ObservedObject var store: AppStore
    public init(store: AppStore) { self.store = store }

    public var body: some View {
        TabView {
            GeneralSettingsView(store: store)
                .tabItem { Label(store.text("general"), systemImage: "gearshape") }
            AppearanceSettingsView(store: store)
                .tabItem { Label(store.text("appearance"), systemImage: "paintpalette") }
            RulesSettingsView(store: store)
                .tabItem { Label(store.text("rules"), systemImage: "list.bullet") }
            ModelSettingsView(store: store)
                .tabItem { Label(store.text("models"), systemImage: "cpu") }
            VStack(spacing: 16) {
                Text(verbatim: "LifeNarrator").font(.title)
                Text("\(store.text("version")) \(NarratorMac.version)")
                Link(store.text("github"), destination: URL(string: "https://github.com/zygs1083-dotcom/LifeNarrator")!)
            }
            .tabItem { Label(store.text("about"), systemImage: "info.circle") }
        }
        .padding(16).frame(width: 780, height: 580)
        .environment(\.locale, Locale(identifier: store.settings.language.lang == .zh ? "zh-Hans" : "en"))
        .alert(store.text("error"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button(store.text("ok")) { store.error = nil }
        } message: { Text(verbatim: store.error ?? "") }
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var store: AppStore
    @State private var showPrivacy = false
    @State private var blacklistText = ""
    var body: some View {
        Form {
            Picker(store.text("language"), selection: $store.settings.language) {
                ForEach(InterfaceLanguage.allCases, id: \.self) { value in
                    Text(store.text("language.\(value.rawValue)")).tag(value)
                }
            }
            Picker(store.text("persona"), selection: $store.settings.persona) {
                ForEach(NarratorCore.Persona.allCases, id: \.self) { value in
                    Text(store.text("persona.\(value.rawValue)")).tag(value)
                }
            }
            KeyboardShortcuts.Recorder(store.text("shortcut.pause"), shortcut: $store.settings.pauseShortcut)
            KeyboardShortcuts.Recorder(store.text("shortcut.input"), shortcut: $store.settings.inputShortcut)
            Toggle(store.text("paused"), isOn: $store.settings.paused)
            Section(store.text("frequency")) {
                Stepper("\(store.text("cooldown")): \(Int(store.settings.ruleCooldown))", value: $store.settings.ruleCooldown, in: 0...3600, step: 30)
                Stepper("\(store.text("perMinute")): \(store.settings.globalPerMinute)", value: $store.settings.globalPerMinute, in: 1...30)
                Stepper("\(store.text("minGap")): \(Int(store.settings.minGap))", value: $store.settings.minGap, in: 0...300)
                Toggle(store.text("freeComment"), isOn: Binding(get: { store.settings.freeComment }, set: { enabled in
                    if enabled { showPrivacy = true } else { store.settings.freeComment = false }
                }))
            }
            Section(store.text("blacklist")) {
                Text(store.text("blacklist.hint")).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $blacklistText)
                .onAppear { blacklistText = store.settings.blacklist.joined(separator: "\n") }
                .onChange(of: blacklistText) { _, value in
                    store.settings.blacklist = value.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
                .font(.system(.body, design: .monospaced)).frame(height: 90)
                .accessibilityLabel(store.text("blacklist"))
            }
        }
        .formStyle(.grouped)
        .alert(store.text("privacy"), isPresented: $showPrivacy) {
            Button(store.text("enable")) { store.settings.freeComment = true }
            Button(store.text("cancel"), role: .cancel) {}
        } message: { Text(store.text("freeComment.privacy")) }
    }
}

private struct AppearanceSettingsView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        HStack(spacing: 16) {
            Form {
                choice("shape", values: BubbleShape.allCases, selection: $store.settings.bubbleStyle.shape)
                choice("size", values: BubbleSize.allCases, selection: $store.settings.bubbleStyle.size)
                choice("theme", values: ColorTheme.allCases, selection: $store.settings.bubbleStyle.theme)
                Section(store.text("effects")) {
                    effect("outline", .outline)
                    effect("shadow", .shadow)
                    effect("gradient", .gradient)
                }
                choice("animation", values: BubbleAnimation.allCases, selection: $store.settings.bubbleStyle.animation)
                choice("emoji", values: EmojiDensity.allCases, selection: $store.settings.bubbleStyle.emojiDensity)
                Picker(store.text("font"), selection: Binding(get: {
                    switch store.settings.bubbleStyle.font {
                    case .persona: "persona"
                    case .fixed(let font): font.rawValue
                    }
                }, set: {
                    store.settings.bubbleStyle.font = $0 == "persona" ? .persona : .fixed(NarratorFont(rawValue: $0)!)
                })) {
                    Text(store.text("font.persona")).tag("persona")
                    ForEach(NarratorFont.allCases, id: \.self) { Text(verbatim: $0.family).tag($0.rawValue) }
                }
                Toggle(store.text("dwell.persistent"), isOn: Binding(get: {
                    store.settings.bubbleStyle.dwell == .untilDismissed
                }, set: { store.settings.bubbleStyle.dwell = $0 ? .untilDismissed : .seconds(6) }))
                if case .seconds(let seconds) = store.settings.bubbleStyle.dwell {
                    Stepper("\(store.text("dwell.seconds")): \(Int(seconds))", value: Binding(get: { seconds }, set: {
                        store.settings.bubbleStyle.dwell = .seconds($0)
                    }), in: 1...60)
                }
                Stepper("\(store.text("maxOnScreen")): \(store.settings.bubbleStyle.maxOnScreen)", value: $store.settings.bubbleStyle.maxOnScreen, in: 1...10)
            }
            .formStyle(.grouped).frame(width: 350)
            VStack(spacing: 24) {
                Text(store.text("preview")).font(.headline)
                preview
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var preview: some View {
        let style = store.settings.bubbleStyle
        let font = BubbleFonts.font(choice: style.font, persona: Persona(rawValue: store.settings.persona.rawValue)!,
                                    language: store.settings.language.lang.rawValue, size: style.size.fontSize)
        let group = style.theme == .random ? ColorSelection.randomGroup(baseHue: 160, index: 0) : style.theme.palette[0]
        var appearance = BubbleAppearance.make(shape: style.shape, size: style.size, theme: style.theme, group: group,
            effects: style.textEffects, font: font, text: store.text("preview.text"),
            emoji: style.emojiDensity == .none ? [] : style.emojiDensity == .many ? ["✨", "🐱", "💬"] : ["✨"], quipID: "preview")
        if style.shape == .speech { appearance.setAppLevelTail(corner: .topRight) }
        return BubbleBodyView(appearance: appearance).padding(20)
    }

    private func choice<T: RawRepresentable & Hashable>(_ key: String, values: [T], selection: Binding<T>) -> some View where T.RawValue == String {
        Picker(store.text(key), selection: selection) {
            ForEach(values, id: \.self) { value in Text(store.text("\(key).\(value.rawValue)")).tag(value) }
        }
    }

    private func effect(_ key: String, _ effect: TextEffects) -> some View {
        Toggle(store.text("effects.\(key)"), isOn: Binding(get: {
            store.settings.bubbleStyle.textEffects.contains(effect)
        }, set: {
            if $0 { store.settings.bubbleStyle.textEffects.insert(effect) }
            else { store.settings.bubbleStyle.textEffects.remove(effect) }
        }))
    }
}

private struct RulesSettingsView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        List {
            Section(store.text("rules.user")) {
                if store.rules.isEmpty { Text(store.text("rules.empty")).foregroundStyle(.secondary) }
                ForEach(store.rules, id: \.id) { rule in
                    HStack {
                        Toggle(rule.label[store.settings.language.lang], isOn: Binding(get: { rule.enabled }, set: { enabled in
                            store.perform { try store.setEnabled(enabled, id: rule.id) }
                        }))
                        Spacer()
                        Text(store.text("kind.\(rule.kind.rawValue)")).foregroundStyle(.secondary)
                        Button(store.text("delete"), role: .destructive) { store.perform { try store.deleteRule(id: rule.id) } }
                    }
                }
            }
            Section(store.text("rules.builtin")) {
                ForEach(store.builtin.rules, id: \.id) { rule in
                    Toggle(rule.label[store.settings.language.lang], isOn: Binding(get: {
                        !store.settings.disabledBuiltinIds.contains(rule.id)
                    }, set: {
                        if $0 { store.settings.disabledBuiltinIds.remove(rule.id) }
                        else { store.settings.disabledBuiltinIds.insert(rule.id) }
                    }))
                }
            }
        }
    }
}
