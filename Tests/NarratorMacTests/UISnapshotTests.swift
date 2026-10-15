import AppKit
import NarratorCore
import SwiftUI
import XCTest
@testable import NarratorMac

@MainActor
final class UISnapshotTests: XCTestCase {
    func testSettingsPagesInLightAndDark() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        application.activate(ignoringOtherApps: true)
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] ?? ".build/snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previousDirectory = ProcessInfo.processInfo.environment["LIFENARRATOR_DATA_DIR"]
        setenv("LIFENARRATOR_DATA_DIR", dataDirectory.path, 1)
        defer {
            if let previousDirectory { setenv("LIFENARRATOR_DATA_DIR", previousDirectory, 1) }
            else { unsetenv("LIFENARRATOR_DATA_DIR") }
        }
        defer { try! FileManager.default.removeItem(at: dataDirectory) }
        var settings = AppSettings()
        settings.language = .zhHans
        settings.provider = .builtin
        try AppDataDirectory().saveSettings(settings)
        let store = try AppStore()
        for dark in [false, true] {
            let view = ScreenRecordingReminder(store: store).padding(20)
                .font(AppTheme.font(.body)).foregroundStyle(AppTheme.textPrimary)
                .groupBoxStyle(.card).frame(width: 780, height: 340).background(AppTheme.windowBackground)
            try render(view, dark: dark, size: NSSize(width: 780, height: 340))
                .write(to: directory.appendingPathComponent("ui-screen-recording-\(dark ? "dark" : "light").png"))
        }
        for tab in SettingsTab.allCases {
            for dark in [false, true] {
                let view = AppSettingsView(store: store, tab: tab)
                let png = try render(view, dark: dark)
                let name = tab == .sprite ? "sprite" : tab.key
                try png.write(to: directory.appendingPathComponent("ui-settings-\(name)-\(dark ? "dark" : "light").png"))
                if [.sprite, .appearance, .general].contains(tab) {
                    let scrolled = try render(view, dark: dark, scrollToBottom: true)
                    try scrolled.write(to: directory.appendingPathComponent("ui-settings-\(name)-scrolled-\(dark ? "dark" : "light").png"))
                }
            }
        }
        var custom = PersonaCatalog.builtin[.teacher]
        custom.id = Persona(rawValue: "custom.snapshot")
        custom.name = .init(zh: "东北大哥", en: "Big Brother")
        custom.caption = .init(zh: "热心爽快的程序员", en: "A warm, straightforward programmer")
        custom.limit = PersonaCatalog.builtin[.gentle].limit
        custom.pack = .gentle
        custom.examples = custom.pack
        try PersonaCatalog(custom: [custom]).save(to: store.directory.personas)
        let customStore = try AppStore()
        customStore.settings.persona = custom.id
        XCTAssertNotNil(customStore.personaModelUnavailableReason)
        for dark in [false, true] {
            let cards = PersonaSettingsView(store: customStore).padding(20)
                .font(AppTheme.font(.body)).foregroundStyle(AppTheme.textPrimary)
                .frame(width: 740, height: 540).background(AppTheme.windowBackground)
            try render(cards, dark: dark, size: NSSize(width: 740, height: 540))
                .write(to: directory.appendingPathComponent("ui-personas-custom-\(dark ? "dark" : "light").png"))
            try render(CustomPersonaView(store: customStore).frame(width: 508, height: 230).background(AppTheme.windowBackground),
                       dark: dark, size: NSSize(width: 508, height: 230))
                .write(to: directory.appendingPathComponent("ui-personas-create-\(dark ? "dark" : "light").png"))
        }
        try customStore.deletePersona(custom.id)
        XCTAssertEqual(customStore.settings.persona, .sharp)
        XCTAssertTrue(try PersonaCatalog.load(from: store.directory.personas).custom.isEmpty)
        store.settings.provider = .api
        for provider in ["zhipu", "ollama"] {
            store.settings.generationAPI = ProviderConfiguration(presetID: provider, model: "fixture")
            for dark in [false, true] {
                let view = ScrollView { ModelSettingsView(store: store).padding(20) }
                    .font(AppTheme.font(.body)).foregroundStyle(AppTheme.textPrimary)
                    .groupBoxStyle(.card).frame(width: 780, height: 580).background(AppTheme.windowBackground)
                try render(view, dark: dark).write(to: directory.appendingPathComponent("ui-provider-\(provider)-\(dark ? "dark" : "light").png"))
            }
        }
        store.settings.provider = .builtin
        let fixtures: [(RuleKind, String, Match)] = [
            (.person, "张三是我领导", Match(aliases: ["张三"], region: .header)),
            (.site, "我讨厌谷歌", Match(domains: ["google.com"])),
            (.topic, "我讨厌开会", Match(aliases: ["开会"]))
        ]
        let rules = fixtures.enumerated().map { index, fixture in
            Rule(id: "snapshot.\(index)", kind: fixture.0, source: .user, input: fixture.1,
                 label: .init(zh: fixture.1, en: fixture.1), sentiment: .dislike,
                 match: fixture.2, highlight: true)
        }
        for filled in [false, true] {
            try RuleLoader.save(filled ? rules : [], to: store.directory.rules)
            let rulesStore = try AppStore()
            for dark in [false, true] {
                let view = ScrollView { RulesSettingsView(store: rulesStore, expanded: filled).padding(20) }
                    .font(AppTheme.font(.body)).foregroundStyle(AppTheme.textPrimary)
                    .groupBoxStyle(.card).toggleStyle(.switch).tint(AppTheme.accent)
                    .frame(width: 780, height: 580).background(AppTheme.windowBackground)
                let name = "ui-rules-\(filled ? "filled" : "empty")-\(dark ? "dark" : "light")"
                try render(view, dark: dark).write(to: directory.appendingPathComponent("\(name).png"))
                if filled {
                    try render(view, dark: dark, scrollToBottom: true)
                        .write(to: directory.appendingPathComponent("\(name)-scrolled.png"))
                }
            }
        }
        for step in 0..<3 {
            try render(OnboardingView(store: store, step: step), dark: false, size: NSSize(width: 620, height: 500))
                .write(to: directory.appendingPathComponent("ui-onboarding-\(step + 1)-light.png"))
        }
        try render(RuleInputView(store: store, onCompiling: { _ in }), dark: false, size: NSSize(width: 600, height: 200))
            .write(to: directory.appendingPathComponent("ui-input-idle-light.png"))
        let states: [(String, InputStatusRow.Status)] = [
            ("compiling", .compiling), ("saved", .saved(label: "张三是我领导", kind: "人物")),
            ("error", .error("无法创建规则：服务连接失败。"))
        ]
        for (name, state) in states {
            let view = InputStatusRow(state: state, language: .zhHans).padding(20).background(AppTheme.card)
            try render(view, dark: false, size: NSSize(width: 600, height: 64))
                .write(to: directory.appendingPathComponent("ui-input-\(name)-light.png"))
        }
        for paused in [false, true] {
            store.settings.paused = paused
            try render(MenuBarView(store: store), dark: false, size: NSSize(width: 240, height: 320))
                .write(to: directory.appendingPathComponent("ui-menu-\(paused ? "paused" : "onDuty")-light.png"))
        }
    }

    func testMemoryAndGrowthInLightAndDark() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] ?? ".build/snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = ProcessInfo.processInfo.environment["LIFENARRATOR_DATA_DIR"]
        setenv("LIFENARRATOR_DATA_DIR", root.path, 1)
        defer {
            if let previous { setenv("LIFENARRATOR_DATA_DIR", previous, 1) }
            else { unsetenv("LIFENARRATOR_DATA_DIR") }
            try! FileManager.default.removeItem(at: root)
        }
        let data = try AppDataDirectory()
        let memoryURL = root.appendingPathComponent("memory.json")
        let growthURL = root.appendingPathComponent("growth.json")
        for language in [InterfaceLanguage.zhHans, .en] {
            let zh = language == .zhHans
            let lang = zh ? "zh" : "en"
            for filled in [false, true] {
                var memories = try MemoryStore(url: memoryURL)
                try memories.clear()
                if filled {
                    let name = try XCTUnwrap(memories.add(kind: .nickname, text: zh ? "叫我阿王" : "Call me Alex", source: .manual))
                    try memories.pin(id: name.id, pinned: true)
                    _ = try memories.add(kind: .fact, text: zh ? "在做人生旁白" : "Building LifeNarrator", source: .chat)
                    _ = try memories.add(kind: .preference, text: zh ? "喜欢茉莉花茶" : "I enjoy jasmine tea", source: .manual)
                    _ = try memories.add(kind: .episode, text: zh ? "认识满 30 天" : "30 days together", source: .stats)
                }
                let rule = Rule(id: "memory.snapshot.rule", kind: .topic, source: .user,
                    input: zh ? "我讨厌开会" : "I dislike meetings",
                    label: .init(zh: "我讨厌开会", en: "I dislike meetings"), sentiment: .dislike,
                    match: Match(aliases: ["开会", "meeting"]), highlight: true)
                try RuleLoader.save(filled ? [rule] : [], to: data.rules)
                var growth = try GrowthTracker(url: root.appendingPathComponent("fixture-growth.json"),
                    now: Date().addingTimeInterval(-32 * 86400)).state
                growth.level = filled ? 15 : 1
                growth.experience = filled ? 9230 : 30
                growth.unlocked = Set(GrowthUnlock.allCases.filter { $0.level <= growth.level })
                growth.consecutiveDays = filled ? 7 : 1
                growth.narrations = filled ? 1420 : 0
                growth.chatMessages = filled ? 86 : 0
                try JSONEncoder().encode(growth).write(to: growthURL)
                var settings = AppSettings()
                settings.language = language
                settings.liveliness = .quiet
                settings.spriteName = zh ? "星仔" : "Stella"
                if filled {
                    settings.bubbleStyle.shape = .star
                    settings.bubbleStyle.theme = .starry
                    settings.bubbleStyle.emoji = "🦊"
                }
                try data.saveSettings(settings)
                let store = try AppStore()
                for dark in [false, true] {
                    let mode = dark ? "dark" : "light"
                    let state = filled ? "filled" : "empty"
                    let memory = AppSettingsView(store: store, tab: .memory)
                    try render(memory, dark: dark)
                        .write(to: directory.appendingPathComponent("ui-memory-\(state)-\(lang)-\(mode).png"))
                    try render(memory, dark: dark, scrollToBottom: true)
                        .write(to: directory.appendingPathComponent("ui-memory-\(state)-scrolled-\(lang)-\(mode).png"))
                    let card = GrowthCard(store: store).padding(20)
                        .font(AppTheme.font(.body)).foregroundStyle(AppTheme.textPrimary)
                        .groupBoxStyle(.card).frame(width: 740, height: 340).background(AppTheme.windowBackground)
                    try render(card, dark: dark, size: NSSize(width: 740, height: 340))
                        .write(to: directory.appendingPathComponent("ui-growth-lv\(growth.level)-\(lang)-\(mode).png"))
                    try render(MenuBarView(store: store), dark: dark, size: NSSize(width: 240, height: 320))
                        .write(to: directory.appendingPathComponent("ui-menu-lv\(growth.level)-\(lang)-\(mode).png"))
                    let appearance = AppSettingsView(store: store, tab: .appearance)
                    let unlock = filled ? "unlocked" : "locked"
                    try render(appearance, dark: dark)
                        .write(to: directory.appendingPathComponent("ui-appearance-\(unlock)-\(lang)-\(mode).png"))
                    try render(appearance, dark: dark, scrollToBottom: true)
                        .write(to: directory.appendingPathComponent("ui-appearance-\(unlock)-scrolled-\(lang)-\(mode).png"))
                }
            }
        }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    private func render<V: View>(_ view: V, dark: Bool, scrollToBottom: Bool = false, size: NSSize = NSSize(width: 780, height: 580)) throws -> Data {
        let bounds = NSRect(origin: .zero, size: size)
        let window = SnapshotWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = bounds
        window.contentView = hosting
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        hosting.layoutSubtreeIfNeeded()
        if scrollToBottom {
            let scroll = try XCTUnwrap(scrollView(in: hosting))
            let document = try XCTUnwrap(scroll.documentView)
            let y = document.isFlipped ? document.bounds.height - scroll.contentView.bounds.height : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            hosting.layoutSubtreeIfNeeded()
        }
        hosting.displayIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: bounds))
        hosting.cacheDisplay(in: bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertFalse(png.isEmpty)
        let first = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 20, y: bitmap.pixelsHigh / 20))
        var hasDifferentColor = false
        for x in 0..<10 {
            for y in 0..<10 {
                let color = try XCTUnwrap(bitmap.colorAt(x: (2 * x + 1) * bitmap.pixelsWide / 20,
                                                       y: (2 * y + 1) * bitmap.pixelsHigh / 20))
                if color != first { hasDifferentColor = true }
            }
        }
        XCTAssertTrue(hasDifferentColor, "UI snapshot of \(V.self) must not be a single color (dark=\(dark), scrolled=\(scrollToBottom))")
        return png
    }
}

@MainActor
private final class SnapshotWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
