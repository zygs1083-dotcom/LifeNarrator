import KeyboardShortcuts
import NarratorCore
import SwiftUI

public enum SettingsTab: CaseIterable {
    case sprite, appearance, memory, rules, models, general
    var key: String {
        switch self {
        case .sprite: "tab.sprite"
        case .appearance: "appearance"
        case .memory: "tab.memory"
        case .rules: "rules"
        case .models: "models"
        case .general: "general"
        }
    }
    var symbol: String {
        switch self {
        case .sprite: "sparkles"
        case .appearance: "paintpalette.fill"
        case .memory: "brain"
        case .rules: "text.badge.checkmark"
        case .models: "brain.head.profile"
        case .general: "gearshape.fill"
        }
    }
    @MainActor var hue: AppTheme.Hue {
        switch self {
        case .sprite: AppTheme.hue(320)
        case .appearance: AppTheme.hue(255)
        case .memory: AppTheme.hue(175)
        case .rules: AppTheme.hue(150)
        case .models: AppTheme.hue(200)
        case .general: AppTheme.hue(42)
        }
    }
}

public struct AppSettingsView: View {
    @ObservedObject var store: AppStore
    @State private var tab: SettingsTab
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(store: AppStore, tab: SettingsTab = .sprite) {
        self.store = store
        _tab = State(initialValue: tab)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(SettingsTab.allCases, id: \.self) { item in
                    Button {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) { tab = item }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.symbol).accessibilityHidden(true)
                            Text(store.text(item.key))
                        }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(tab == item ? item.hue.text : AppTheme.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background {
                            if tab == item {
                                Capsule().fill(item.hue.soft)
                                    .overlay(Capsule().stroke(item.hue.stroke, lineWidth: 1))
                                    .matchedGeometryEffect(id: "tab", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                }
            }
            .padding(.leading, 78).padding(.trailing, 20).frame(maxWidth: .infinity).frame(height: 52)
            ScrollView {
                Group {
                    switch tab {
                    case .sprite: SpriteSettingsView(store: store)
                    case .appearance: AppearanceSettingsView(store: store)
                    case .memory: MemorySettingsView(store: store, showRules: { tab = .rules })
                    case .rules: RulesSettingsView(store: store)
                    case .models: ModelSettingsView(store: store)
                    case .general: GeneralSettingsView(store: store)
                    }
                }
                .id(tab).transition(.opacity)
                .padding(20)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: tab)
            }
        }
        .font(AppTheme.font(.body)).foregroundStyle(AppTheme.textPrimary)
        .groupBoxStyle(.card).toggleStyle(.switch).tint(AppTheme.accent)
        .frame(width: 780, height: 580).background(AppTheme.windowBackground)
        .ignoresSafeArea()
        .transaction { if reduceMotion { $0.disablesAnimations = true } }
        .environment(\.locale, Locale(identifier: store.settings.language.lang == .zh ? "zh-Hans" : "en"))
        .alert(store.text("error"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button(store.text("ok")) { store.error = nil }
        } message: { Text(verbatim: store.error ?? "") }
    }
}

private struct SpriteSettingsView: View {
    @ObservedObject var store: AppStore
    private let hue = AppTheme.hue(320)
    var body: some View {
        VStack(spacing: 14) {
            GrowthCard(store: store)
            if !store.screenRecordingGranted && store.settings.liveliness != .quiet {
                ScreenRecordingReminder(store: store)
            }
            GroupBox {
                Text(store.text("sprite.onDuty.hint")).font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
            } label: {
                HStack {
                    CardHeading(title: store.text("sprite.onDuty"), symbol: "sparkles", hue: hue)
                    Spacer()
                    if let shortcut = store.settings.pauseShortcut { Badge(text: shortcut.description, hue: hue) }
                    Toggle(store.text("sprite.onDuty"), isOn: Binding(get: { !store.settings.paused }, set: { store.settings.paused = !$0 }))
                        .labelsHidden()
                }
            }
            GroupBox {
                ChoiceCards(options: zip([Liveliness.quiet, .lively, .rowdy], ["🤫", "🎉", "🔊"]).map {
                    (value: $0.0, emoji: $0.1, title: store.text("liveliness.\($0.0.rawValue)"), caption: store.text("liveliness.\($0.0.rawValue).hint"))
                }, selection: $store.settings.liveliness, hue: hue)
                Text(store.text("liveliness.hint")).font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
                if store.settings.provider == .api && store.settings.generationAPI.isCloud && store.settings.liveliness != .quiet {
                    Badge(text: store.text("api.privacy"), hue: AppTheme.hue(42))
                }
            } label: { CardHeading(title: store.text("liveliness"), symbol: "speaker.wave.2.fill", hue: hue) }
            GroupBox {
                SliderRow(title: store.text("pace.gap"), hint: store.text("pace.gap.hint"), value: $store.settings.markGap,
                          range: 1...30, format: seconds, hue: hue)
                LabeledContent(store.text("dwell.persistent")) {
                    Toggle(store.text("dwell.persistent"), isOn: Binding(get: {
                        store.settings.bubbleStyle.dwell == .untilDismissed
                    }, set: { store.settings.bubbleStyle.dwell = $0 ? .untilDismissed : .seconds(3) })).labelsHidden().frame(maxWidth: .infinity, alignment: .trailing)
                }.frame(minHeight: 28)
                if case .seconds(let duration) = store.settings.bubbleStyle.dwell {
                    SliderRow(title: store.text("pace.dwell"), value: Binding(get: { duration }, set: {
                        store.settings.bubbleStyle.dwell = .seconds($0)
                    }), range: 1...30, format: seconds, hue: hue)
                    if store.settings.bubbleStyle.maxOnScreen > 3 {
                        Text(String(format: store.text("pace.dwell.hint"), 2.5 * Double(store.settings.bubbleStyle.maxOnScreen)))
                            .font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
                    }
                }
                SliderRow(title: store.text("pace.maxOnScreen"), value: Binding(get: {
                    Double(store.settings.bubbleStyle.maxOnScreen)
                }, set: { store.settings.bubbleStyle.maxOnScreen = Int($0) }), range: 1...10,
                          format: { String(format: store.text("format.count"), $0) }, hue: hue)
                Text(store.text("pace.maxOnScreen.hint"))
                    .font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
            } label: { CardHeading(title: store.text("pace"), symbol: "metronome", hue: hue, caption: store.text("pace.hint")) }
            GroupBox {
                PersonaSettingsView(store: store)
            } label: { CardHeading(title: store.text("persona"), symbol: "person.fill", hue: hue, caption: store.text("persona.hint")) }
        }
    }
    private func seconds(_ value: Int) -> String { String(format: store.text("format.seconds"), value) }
}

struct ScreenRecordingReminder: View {
    @ObservedObject var store: AppStore
    private let hue = AppTheme.hue(42)

    var body: some View {
        GroupBox {
            ScreenRecordingRepair(store: store)
            Text(store.text("screenRecording.body"))
                .font(AppTheme.font(.body)).foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(store.text("screenRecording.open")) { store.openScreenRecordingSettings() }
                    .buttonStyle(AppTheme.CapsuleButton(hue: hue))
                Button(store.text("screenRecording.relaunch")) { store.relaunch() }
                    .buttonStyle(AppTheme.CapsuleButton(hue: hue, filled: false))
            }
        } label: {
            CardHeading(title: store.text("screenRecording.title"), symbol: "record.circle", hue: hue)
        }
    }
}

struct ScreenRecordingRepair: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.text("screenRecording.repair"))
                .font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(store.text("screenRecording.copyCommand")) { store.copyScreenRecordingResetCommand() }
                .buttonStyle(AppTheme.CapsuleButton(hue: AppTheme.hue(42), filled: false))
        }
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var store: AppStore
    @State private var blacklistText = ""
    private let hue = AppTheme.hue(42)
    var body: some View {
        VStack(spacing: 14) {
            GroupBox {
                Picker(store.text("language"), selection: $store.settings.language) {
                    ForEach(InterfaceLanguage.allCases, id: \.self) { value in
                        Text(store.text("language.\(value.rawValue)")).tag(value)
                    }
                }.pickerStyle(.menu).frame(minHeight: 28)
            } label: { CardHeading(title: store.text("language"), symbol: "globe", hue: hue) }
            UpdateSettingsView(store: store, updater: store.updater)
            GroupBox {
                LabeledContent(store.text("shortcut.pause")) {
                    KeyboardShortcuts.Recorder("", shortcut: $store.settings.pauseShortcut)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }.frame(minHeight: 28)
                LabeledContent(store.text("shortcut.chat")) {
                    KeyboardShortcuts.Recorder("", shortcut: $store.settings.chatShortcut)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }.frame(minHeight: 28)
                LabeledContent(store.text("shortcut.input")) {
                    KeyboardShortcuts.Recorder("", shortcut: $store.settings.inputShortcut)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }.frame(minHeight: 28)
            } label: { CardHeading(title: store.text("shortcuts"), symbol: "keyboard", hue: hue) }
            GroupBox {
                TextEditor(text: $blacklistText)
                    .onAppear { blacklistText = store.settings.blacklist.joined(separator: "\n") }
                    .onChange(of: blacklistText) { _, value in
                        store.settings.blacklist = value.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
                    .font(.system(size: 12, design: .monospaced)).frame(height: 90)
                    .scrollContentBackground(.hidden).padding(4)
                    .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.cardStroke, lineWidth: 1))
                    .accessibilityLabel(store.text("blacklist"))
            } label: { CardHeading(title: store.text("blacklist"), symbol: "hand.raised.fill", hue: hue, caption: store.text("blacklist.hint")) }
            GroupBox {
                HStack(spacing: 12) {
                    Image(systemName: "text.bubble.fill").font(.system(size: 44)).foregroundStyle(AppTheme.accentText)
                        .frame(width: 56, height: 56).background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityHidden(true)
                    Text(verbatim: "LifeNarrator").font(.system(size: 15, weight: .semibold, design: .rounded))
                    Badge(text: "\(store.text("version")) \(NarratorMac.version)", hue: hue)
                }
                HStack {
                    Link(store.text("github"), destination: URL(string: "https://github.com/zygs1083-dotcom/LifeNarrator")!)
                        .foregroundStyle(AppTheme.accentDeep)
                    Spacer()
                    Button(store.text("quit")) { NSApplication.shared.terminate(nil) }
                        .buttonStyle(AppTheme.CapsuleButton(filled: false))
                }
            } label: { CardHeading(title: store.text("about"), symbol: "info.circle", hue: hue) }
        }
    }
}

private struct AppearanceSettingsView: View {
    @ObservedObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let hue = AppTheme.hue(255)
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 14) {
                GroupBox {
                    choice("shape", values: BubbleShape.allCases, selection: $store.settings.bubbleStyle.shape,
                           unlock: { $0 == .star ? .starBubble : nil }).pickerStyle(.menu)
                    if !store.isUnlocked(.starBubble) { UnlockLabel(store: store, unlock: .starBubble) }
                    choice("size", values: BubbleSize.allCases, selection: $store.settings.bubbleStyle.size).pickerStyle(.segmented)
                    Picker(store.text("font"), selection: Binding(get: {
                        switch store.settings.bubbleStyle.font {
                        case .persona: "persona"
                        case .fixed(let font): font.rawValue
                        }
                    }, set: { store.settings.bubbleStyle.font = $0 == "persona" ? .persona : .fixed(NarratorFont(rawValue: $0)!) })) {
                        Text(store.text("font.persona")).tag("persona")
                        ForEach(NarratorFont.allCases, id: \.self) { Text(verbatim: $0.family).tag($0.rawValue) }
                    }.pickerStyle(.menu).frame(minHeight: 28)
                } label: { CardHeading(title: store.text("appearance.look"), symbol: "bubble.left.fill", hue: hue) }
                GroupBox {
                    choice("theme", values: ColorTheme.allCases, selection: $store.settings.bubbleStyle.theme,
                           unlock: { $0 == .starry ? .starryTheme : nil }).pickerStyle(.menu)
                    if !store.isUnlocked(.starryTheme) { UnlockLabel(store: store, unlock: .starryTheme) }
                    effect("outline", .outline)
                    effect("shadow", .shadow)
                    effect("gradient", .gradient)
                } label: { CardHeading(title: store.text("appearance.color"), symbol: "paintpalette.fill", hue: hue) }
                GroupBox {
                    choice("animation", values: BubbleAnimation.allCases, selection: Binding(get: { store.settings.bubbleStyle.animation }, set: { store.settings.bubbleStyle.animation = $0 })).pickerStyle(.menu)
                    choice("emoji", values: EmojiDensity.allCases, selection: $store.settings.bubbleStyle.emojiDensity).pickerStyle(.segmented)
                    Picker(store.text("emoji.selection"), selection: Binding(get: {
                        store.settings.bubbleStyle.emoji ?? ""
                    }, set: { store.settings.bubbleStyle.emoji = $0.isEmpty ? nil : $0 })) {
                        Text(store.text("emoji.automatic")).tag("")
                        ForEach(BubbleStyle.extraEmoji, id: \.self) { emoji in
                            Group {
                                if store.isUnlocked(.emoji) { Text(verbatim: emoji) }
                                else { Label("\(emoji) · Lv.\(GrowthUnlock.emoji.level)", systemImage: "lock.fill") }
                            }.tag(emoji).disabled(!store.isUnlocked(.emoji))
                        }
                    }.pickerStyle(.menu).frame(minHeight: 28)
                    if !store.isUnlocked(.emoji) { UnlockLabel(store: store, unlock: .emoji) }
                } label: { CardHeading(title: store.text("appearance.motion"), symbol: "wind", hue: hue) }
            }.frame(width: 380)
            GroupBox {
                fakeWindow
            } label: { CardHeading(title: store.text("preview"), symbol: "eye.fill", hue: hue, caption: store.text("preview.hint")) }
        }
    }

    private var previewID: String {
        let style = store.settings.bubbleStyle
        return "\(style.shape)-\(style.size)-\(style.theme)-\(style.textEffects.rawValue)-\(style.animation)-\(style.emojiDensity)-\(style.emoji ?? "")-\(style.font)-\(store.settings.persona)-\(store.settings.language)"
    }

    private var fakeWindow: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { hex in
                        Circle().fill(Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255))
                            .frame(width: 8, height: 8)
                    }
                    Spacer()
                }.padding(.horizontal, 10).frame(height: 22)
                Rectangle().fill(AppTheme.cardStroke).frame(height: 1)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach([0.60, 0.80, 0.45], id: \.self) { fraction in
                        Capsule().fill(AppTheme.textSecondary.opacity(0.25)).frame(width: 320 * fraction, height: 8)
                    }
                }.padding(16)
                Spacer()
            }
            preview.id(previewID)
                .transition(BubbleTransitions.bubble(store.settings.bubbleStyle.animation, anchor: .topTrailing,
                                                     slide: CGSize(width: 18, height: 0), delay: 0, reduceMotion: reduceMotion))
                .padding(.top, 34).padding(.trailing, 16)
        }
        .frame(width: 320, height: 200)
        .background(AppTheme.windowBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.cardStroke, lineWidth: 1))
        .animation(.default, value: previewID)
        .accessibilityElement(children: .ignore).accessibilityLabel(store.text("preview"))
    }

    private var preview: some View {
        let style = store.settings.bubbleStyle
        let font = BubbleFonts.font(choice: style.font, persona: store.settings.persona,
                                    language: store.settings.language.lang.rawValue, size: style.size.fontSize, catalog: store.personas)
        let group = style.theme == .random ? ColorSelection.randomGroup(baseHue: 160, index: 0) : style.theme.palette[0]
        var appearance = BubbleAppearance.make(shape: style.shape, size: style.size, theme: style.theme, group: group,
            effects: style.textEffects, font: font, text: store.text("preview.text"),
            emoji: style.displayedEmoji(["✨", "🐱", "💬"]), quipID: "preview")
        if style.shape == .speech { appearance.setAppLevelTail(corner: .topRight) }
        return BubbleBodyView(appearance: appearance)
    }

    private func choice<T: RawRepresentable & Hashable>(_ key: String, values: [T], selection: Binding<T>,
                                                       unlock: @escaping (T) -> GrowthUnlock? = { _ in nil }) -> some View where T.RawValue == String {
        Picker(store.text(key), selection: selection) {
            ForEach(values, id: \.self) { value in
                let required = unlock(value)
                let locked = required.map { !store.isUnlocked($0) } ?? false
                Group {
                    if locked {
                        Label("\(store.text("\(key).\(value.rawValue)")) · Lv.\(required!.level)", systemImage: "lock.fill")
                    } else { Text(store.text("\(key).\(value.rawValue)")) }
                }.tag(value).disabled(locked)
            }
        }.frame(minHeight: 28)
    }

    private func effect(_ key: String, _ effect: TextEffects) -> some View {
        LabeledContent(store.text("effects.\(key)")) {
            Toggle(store.text("effects.\(key)"), isOn: Binding(get: {
                store.settings.bubbleStyle.textEffects.contains(effect)
            }, set: {
                if $0 { store.settings.bubbleStyle.textEffects.insert(effect) }
                else { store.settings.bubbleStyle.textEffects.remove(effect) }
            })).labelsHidden().frame(maxWidth: .infinity, alignment: .trailing)
        }.frame(minHeight: 28)
    }
}
