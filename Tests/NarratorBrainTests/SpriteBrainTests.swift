import Foundation
import Testing
import NarratorCore
@testable import NarratorBrain

private actor BrainGenerator: TextGenerator {
    nonisolated let changes = AsyncStream<Void>.makeStream()
    var prompts: [String] = []
    var systems: [String?] = []
    var cancelled: Set<Int> = []
    private var pending: [Int: CheckedContinuation<String, any Error>] = [:]

    func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?) async throws -> String {
        let id = prompts.count
        prompts.append(prompt)
        systems.append(system)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending[id] = $0; changes.continuation.yield(()) }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func complete(_ id: Int, _ json: String) { pending.removeValue(forKey: id)!.resume(returning: json) }
    private func cancel(_ id: Int) {
        cancelled.insert(id)
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
        changes.continuation.yield(())
    }
}

@MainActor private final class BrainTestSensor: BrainSensor {
    let changes = AsyncStream<Void>.makeStream()
    var typing = false
    var idle: TimeInterval = 0
    var lowPower = false
    var lines: [TextLine] = []
    var ranges: [NSRange] = []
    var pauseRect = false
    var rectWaiter: CheckedContinuation<Void, Never>?

    func isTyping(now: Date) async throws -> Bool { typing }
    func isSecureFocused() async throws -> Bool { false }
    func idleSeconds() async -> TimeInterval { idle }
    func lastTypedAt() async -> Date { .distantPast }
    func isLowPowerMode() async -> Bool { lowPower }
    func refresh() async {}
    func boundsProbe() async throws -> Bool { true }
    func startVisualLines() async {}
    func textRect(lineIndex: Int, range: NSRange) async throws -> (rect: CGRect, kind: RectKind)? {
        ranges.append(range)
        let rect = lines[lineIndex].rect
        if pauseRect {
            pauseRect = false
            await withCheckedContinuation { rectWaiter = $0; changes.continuation.yield(()) }
        }
        return (rect, .bounds)
    }
    func markTrack(lineIndex: Int, kind: RectKind?) async throws -> String? { "track-\(lineIndex)" }
    func unframedRect(lineIndex: Int, range: NSRange) async -> CGRect { lines[lineIndex].rect }
    func placementLine(lineIndex: Int, rect: CGRect, kind: RectKind?) async -> CGRect { rect }
    func placementObstacles(in contentFrame: CGRect) async -> [CGRect] {
        return []
    }
}

@MainActor private final class BrainTestOverlay: BrainOverlay {
    let changes = AsyncStream<Void>.makeStream()
    var narrations: [Narration] = []
    var dismissals = 0
    var pauseNext = false
    var showCalls = 0
    var showWaiter: CheckedContinuation<Void, Never>?
    func show(_ narration: Narration) async -> (shown: Bool, placement: String) {
        showCalls += 1
        if pauseNext {
            pauseNext = false
            await withCheckedContinuation { showWaiter = $0; changes.continuation.yield(()) }
        }
        narrations.append(narration)
        changes.continuation.yield(())
        return (true, "right")
    }
    func dismissAll() async { dismissals += 1 }
    func follow() async {}
    func highlight(id: String) async -> CGRect? { narrations.first { $0.id == id }?.anchor }
    func windowFrameChanged(windowID: UInt32, window: WindowGeometry) async {}
}

@MainActor private final class BrainTestHost: BrainHost {
    let changes = AsyncStream<Void>.makeStream()
    func saveRule(input: String) async throws {}
    func applySetting(_ setting: ChatSetting) async throws {}

    var errors: [String] = []
    func report(_ error: any Error) async {
        errors.append(String(describing: error))
        changes.continuation.yield(())
    }
}

@MainActor private final class BrainFixture {
    let sensor = BrainTestSensor()
    let overlay = BrainTestOverlay()
    let host = BrainTestHost()
    let directory: URL
    let saidURL: URL
    let brain: SpriteBrain
    var settings = BrainSettings(liveliness: .lively, markGap: 0, paused: false, blacklist: [], persona: .gentle,
        lang: .zh, disabledBuiltinIds: [], maxOnScreen: 8, modelAvailable: true, systemOne: nil, ownProcessID: 999)
    var content = BrainContent(rules: [], builtin: QuipPack(version: 1, rules: [], generic: [:]), personas: .builtin)

    init(said: SaidHistory? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        saidURL = directory.appendingPathComponent("said.json")
        if let said { try JSONEncoder().encode(said).write(to: saidURL) }
        brain = try SpriteBrain(sensor: sensor, overlay: overlay, host: host, saidURL: saidURL)
    }

    func configure(_ generator: (any TextGenerator)? = nil) {
        settings.modelAvailable = generator != nil
        brain.configure(settings: settings, content: content, generator: .success(generator))
    }

    func snapshot(_ texts: [String] = ["quoted first phrase"], window: UInt32 = 1, switching: Bool = true,
                  capturedAt: Date = Date(), bundle: String = "fixture") {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        sensor.lines = texts.enumerated().map {
            TextLine(text: $0.element, rect: CGRect(x: 100, y: 100 + $0.offset * 80, width: 300, height: 20))
        }
        brain.snapshot(ContextSnapshot(bundleId: bundle, appName: "Fixture", pid: 1,
            windowFrame: frame, contentFrame: frame, textLines: sensor.lines, textSource: .ax, capturedAt: capturedAt),
            windowID: window, change: ContextChange(appChanged: switching, windowChanged: switching, hostChanged: false))
    }

    func finish() throws {
        brain.windowChanged()
        #expect(host.errors.isEmpty)
        try FileManager.default.removeItem(at: directory)
    }
}

@MainActor private func eventually(_ changes: AsyncStream<Void>, _ condition: () async -> Bool) async throws {
    if await condition() { return }
    for await _ in changes {
        if await condition() { return }
    }
    try #require(await condition())
}

private let firstMark = #"{"marks":[{"l":0,"q":"first phrase","t":"咖啡还没凉","e":"🌷"}]}"#

@Suite(.serialized) @MainActor struct SpriteBrainScenarios {
    @Test func memoryAndRelationshipOnlyChangeUserPrompt() async throws {
        let f = try BrainFixture(), generator = BrainGenerator()
        f.configure(generator)
        try f.brain.addMemory(kind: .nickname, text: "阿王")
        try f.brain.addMemory(kind: .fact, text: "You enjoy writing Swift")
        try f.brain.addMemory(kind: .episode, text: "昨天凌晨三点还在输入", source: .stats)
        f.snapshot(["Writing Swift with first phrase"])
        try await eventually(generator.changes.stream) { await generator.prompts.count == 1 }
        let user = await generator.prompts[0]
        #expect(user.contains("你记得的事："))
        #expect(user.contains("阿王"))
        #expect(user.contains("You enjoy writing Swift"))
        #expect(user.contains("刚认识，客气一点"))
        let baseline = GenerationPrompts.spriteMarks(app: "Fixture", title: "", screen: SpriteScreen(lines: [], tokens: 0),
            exclude: [], persona: .gentle, lang: .zh,
            k: SpriteTick.requestCount(level: f.settings.liveliness, maxOnScreen: f.settings.maxOnScreen))
        #expect(await generator.systems[0] == baseline.system)
        #expect(f.brain.memories.allSatisfy { $0.uses == 1 })
        let context = try f.brain.memoryContext()
        #expect(context.contains("阿王"))
        #expect(context.contains("昨天凌晨三点还在输入"))
        #expect(!context.contains("You enjoy writing Swift"))
        let json = String(decoding: try Data(contentsOf: f.directory.appendingPathComponent("memory.json")), as: UTF8.self)
        #expect(!json.contains("first phrase"))
        let growth = String(decoding: try Data(contentsOf: f.directory.appendingPathComponent("growth.json")), as: UTF8.self)
        #expect(!growth.contains("Writing Swift"))
        try f.finish()
    }

    @Test func ambientIncludesNicknameEpisodesAndRelationshipWithStableSystem() async throws {
        for lang in [Lang.zh, .en] {
            let f = try BrainFixture(), generator = BrainGenerator()
            f.settings.lang = lang
            f.configure()
            try f.brain.addMemory(kind: .nickname, text: "阿王")
            try f.brain.addMemory(kind: .episode, text: "昨天凌晨三点还在输入", source: .stats)
            let signals = SpriteAmbientSignals(app: "Fixture", title: "", minutes: 10, hour: 12,
                minute: 0, switches: 1, typedRecently: true)
            let context = try f.brain.memoryContext()
            let task = Task {
                try await SpriteAmbient.generate(signals: signals, persona: .gentle, lang: lang,
                    recent: [], generator: generator, memoryContext: context)
            }
            try await eventually(generator.changes.stream) { await generator.prompts.count == 1 }
            #expect(await generator.prompts[0].contains("阿王"))
            #expect(await generator.prompts[0].contains("昨天凌晨三点还在输入"))
            #expect(await generator.prompts[0].contains(lang == .zh ? "刚认识" : "You just met"))
            let baseline = SpriteAmbient.prompt(signals: signals, persona: .gentle, lang: lang, recent: [])
            #expect(await generator.systems[0] == baseline.system)
            await generator.complete(0, #"{"lines":[{"t":"茶还温着","e":"🍵"},{"t":"窗外有光","e":"☀️"},{"t":"键盘开花了","e":"🌷"}]}"#)
            _ = try await task.value
            try f.finish()
        }
    }

    @Test func disabledMemoryNeitherRecordsNorUsesAndRetainsExistingMemories() async throws {
        let f = try BrainFixture(), generator = BrainGenerator()
        f.configure(generator)
        let entry = try #require(try f.brain.addMemory(kind: .nickname, text: "阿王"))
        let url = f.directory.appendingPathComponent("memory.json")
        let before = try Data(contentsOf: url)
        f.settings.memoryEnabled = false
        f.configure(generator)
        #expect(try f.brain.addMemory(kind: .fact, text: "No new facts") == nil)
        #expect(try !f.brain.memoryContext(screenText: "阿王").contains("阿王"))
        #expect(try !f.brain.memoryContext().contains("你记得的事"))
        f.snapshot()
        try await eventually(generator.changes.stream) { await generator.prompts.count == 1 }
        #expect(await !generator.prompts[0].contains("阿王"))
        #expect(await !generator.prompts[0].contains("你记得的事"))
        #expect(f.brain.memories.map(\.id) == [entry.id])
        #expect(try Data(contentsOf: url) == before)
        f.settings.memoryEnabled = true
        f.configure(generator)
        #expect(try f.brain.memoryContext().contains("阿王"))
        #expect(f.brain.memories[0].uses == 1)
        try f.finish()
    }

    @Test func levelUpUsesCornerAndSaidHistory() async throws {
        for repeatAlreadySaid in [false, true] {
            var said = SaidHistory()
            let text = GrowthMilestone.level(2).text(lang: .zh)
            if repeatAlreadySaid { said.record(text, now: Date()) }
            let f = try BrainFixture(said: said)
            f.settings.liveliness = .quiet
            f.configure()
            for _ in 0..<7 { try f.brain.recordGrowth(.rule) }
            #expect(f.brain.growthState.level == 2)
            f.snapshot([])
            if repeatAlreadySaid {
                try await Task.sleep(for: .milliseconds(100))
                #expect(f.overlay.narrations.isEmpty)
            } else {
                try await eventually(f.overlay.changes.stream) { f.overlay.narrations.count == 1 }
                #expect(f.overlay.narrations[0].text == text)
                #expect(f.overlay.narrations[0].ruleID == "sprite-growth")
                #expect(f.overlay.narrations[0].anchor == nil)
                let history = try JSONDecoder().decode(SaidHistory.self, from: Data(contentsOf: f.saidURL))
                #expect(history.isRepeat(text, now: Date()))
                #expect(f.brain.growthState.narrations == 1)
            }
            f.snapshot([], window: 2)
            try await Task.sleep(for: .milliseconds(100))
            #expect(f.overlay.narrations.count == (repeatAlreadySaid ? 0 : 1))
            try f.finish()
        }
    }

    @Test func contentUpdatesKeepRequestAndLocateAgainstLatestLines() async throws {
        let f = try BrainFixture(), generator = BrainGenerator()
        f.configure(generator)
        f.snapshot()
        try await eventually(generator.changes.stream) { await generator.prompts.count == 1 }
        let experience = f.brain.growthState.experience
        f.snapshot(["unrelated heading", "quoted first phrase"], switching: false)
        #expect(await generator.cancelled.isEmpty)
        await generator.complete(0, firstMark)
        try await eventually(f.overlay.changes.stream) { f.overlay.narrations.count == 1 }
        let narration = try #require(f.overlay.narrations.first)
        #expect(narration.windowID == 1)
        #expect(narration.trackID == "track-1")
        #expect(narration.anchor?.minY == 180)
        let history = try JSONDecoder().decode(SaidHistory.self, from: Data(contentsOf: f.saidURL))
        #expect(history.isRepeat("咖啡还没凉", now: Date()))
        #expect(f.brain.growthState.narrations == 1)
        #expect(f.brain.growthState.experience == experience + 1)
        try f.finish()
    }

    @Test func switchingCancelsRequestAndStartsForNewWindow() async throws {
        let f = try BrainFixture(), generator = BrainGenerator()
        f.configure(generator)
        f.snapshot()
        try await eventually(generator.changes.stream) { await generator.prompts.count == 1 }
        f.snapshot(window: 2)
        try await eventually(generator.changes.stream) { let cancelled = await generator.cancelled.contains(0)
            let count = await generator.prompts.count
            return cancelled && count == 2 }
        await generator.complete(1, firstMark)
        try await eventually(f.overlay.changes.stream) { f.overlay.narrations.count == 1 }
        #expect(f.overlay.narrations.first?.windowID == 2)
        try f.finish()
    }

    @Test func typingDefersDisplayUntilTypingStops() async throws {
        let f = try BrainFixture(), generator = BrainGenerator()
        f.sensor.typing = true
        f.configure(generator)
        f.snapshot()
        try await eventually(generator.changes.stream) { await generator.prompts.count == 1 }
        await generator.complete(0, firstMark)
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.overlay.narrations.isEmpty)
        f.sensor.typing = false
        try await eventually(f.overlay.changes.stream) { f.overlay.narrations.count == 1 }
        try f.finish()
    }

    @Test func finalDisplayRejectsQuipSaidWhileWaiting() async throws {
        let f = try BrainFixture(), generator = BrainGenerator()
        f.sensor.typing = true
        f.overlay.pauseNext = true
        let quip = Quip(lang: .zh, persona: .gentle, text: "咖啡还没凉", emoji: ["🌷"])
        f.content.rules = [Rule(id: "rule", kind: .topic, source: .user, label: Label(zh: "标题", en: "Title"),
            sentiment: .neutral, match: Match(aliases: ["another phrase"]), highlight: true, quips: [quip])]
        f.configure(generator)
        f.snapshot(["another phrase", "quoted first phrase"])
        try await eventually(generator.changes.stream) { await generator.prompts.count == 1 }
        await generator.complete(0, #"{"marks":[{"l":1,"q":"first phrase","t":"咖啡还没凉","e":"🌷"}]}"#)
        try await Task.sleep(for: .milliseconds(100))
        f.sensor.typing = false
        try await eventually(f.overlay.changes.stream) { f.overlay.showWaiter != nil }
        try await Task.sleep(for: .milliseconds(300))
        #expect(f.overlay.showCalls == 1)
        try #require(f.overlay.showWaiter).resume()
        f.overlay.showWaiter = nil
        try await eventually(f.overlay.changes.stream) { f.overlay.narrations.count == 1 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(f.overlay.narrations.count == 1)
        try f.finish()
    }

    @Test func rowdyPrefetchesButIdleStopsPrefetchAndAmbient() async throws {
        let f = try BrainFixture(), generator = BrainGenerator()
        f.settings.liveliness = .rowdy
        f.sensor.typing = true
        f.configure(generator)
        f.snapshot()
        try await eventually(generator.changes.stream) { await generator.prompts.count == 1 }
        await generator.complete(0, firstMark)
        try await eventually(generator.changes.stream) { await generator.prompts.count == 2 }
        f.sensor.idle = 120
        await generator.complete(1, #"{"marks":[]}"#)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(await generator.prompts.count == 2)
        try f.finish()

        let idle = try BrainFixture(), idleGenerator = BrainGenerator()
        idle.settings.liveliness = .rowdy
        idle.sensor.idle = 120
        idle.configure(idleGenerator)
        idle.snapshot(capturedAt: Date().addingTimeInterval(-60))
        try await eventually(idleGenerator.changes.stream) { await idleGenerator.prompts.count == 1 }
        await idleGenerator.complete(0, #"{"marks":[]}"#)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(await idleGenerator.prompts.count == 1)
        idle.sensor.idle = 0
        try await eventually(idleGenerator.changes.stream) { await idleGenerator.prompts.count == 2 }
        #expect(await idleGenerator.prompts[1].contains("Fixture"))
        try idle.finish()
    }

    @Test func openerHonorsCooldownAcrossWindowSwitches() async throws {
        let f = try BrainFixture()
        f.settings.liveliness = .rowdy
        let rule = Rule(id: "opener", kind: .app, source: .builtin, label: Label(zh: "应用", en: "App"),
            sentiment: .neutral, match: Match(bundleIds: ["fixture"]), highlight: false,
            quips: ["咖啡还没凉", "小苗雨天备案", "知识列车进站"].map { Quip(lang: .zh, persona: .gentle, text: $0, emoji: ["🌷"]) })
        f.content.builtin.rules = [rule]
        f.configure()
        f.snapshot([])
        try await eventually(f.overlay.changes.stream) { f.overlay.narrations.count == 1 }
        f.snapshot([], window: 2)
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.overlay.narrations.count == 1)
        try f.finish()
    }

    @Test func lowPowerDoesNotRequestModel() async throws {
        let f = try BrainFixture(), generator = BrainGenerator()
        f.sensor.lowPower = true
        f.configure(generator)
        f.snapshot()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await generator.prompts.isEmpty)
        try f.finish()
    }

    @Test func invalidGeneratorConfigurationStillAppliesPauseAndReportsWhenUsed() async throws {
        enum InvalidConfiguration: Error { case invalidURL }
        let f = try BrainFixture()
        f.settings.paused = true
        f.brain.configure(settings: f.settings, content: f.content, generator: .failure(InvalidConfiguration.invalidURL))
        f.snapshot()
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.host.errors.isEmpty)
        f.settings.paused = false
        f.brain.configure(settings: f.settings, content: f.content, generator: .failure(InvalidConfiguration.invalidURL))
        try await eventually(f.host.changes.stream) { !f.host.errors.isEmpty }
        #expect(f.host.errors.allSatisfy { $0 == "invalidURL" })
        f.host.errors = []
        try f.finish()
    }

    @Test func invalidSystemOneConnectionOnlyFailsWhenDecisionIsNeeded() async throws {
        enum InvalidConfiguration: Error { case invalidURL }
        let f = try BrainFixture()
        f.settings.liveliness = .quiet
        f.settings.systemOne = .init(model: "", connection: .failure(InvalidConfiguration.invalidURL))
        var rule = Rule(id: "app", kind: .app, source: .user, label: Label(zh: "应用", en: "App"),
            sentiment: .neutral, match: Match(bundleIds: ["fixture"]), highlight: false,
            quips: [Quip(lang: .zh, persona: .gentle, text: "咖啡还没凉", emoji: ["🌷"])])
        f.content.rules = [rule]
        f.configure()
        f.snapshot([])
        try await eventually(f.overlay.changes.stream) { f.overlay.narrations.count == 1 }
        #expect(f.host.errors.isEmpty)
        rule.id = "topic"
        rule.kind = .topic
        rule.match = Match(aliases: ["first phrase"])
        f.content.rules = [rule]
        f.configure()
        f.snapshot(window: 2)
        try await eventually(f.host.changes.stream) { !f.host.errors.isEmpty }
        #expect(f.host.errors.allSatisfy { $0 == "invalidURL" })
        #expect(f.overlay.narrations.count == 1)
        f.host.errors = []
        try f.finish()
    }

    @Test func suspendedGeometryRelocatesAndUsesUTF16Ranges() async throws {
        let f = try BrainFixture(), generator = BrainGenerator()
        f.sensor.pauseRect = true
        f.configure(generator)
        f.snapshot(["🌷 quoted first phrase"])
        try await eventually(generator.changes.stream) { await generator.prompts.count == 1 }
        await generator.complete(0, firstMark)
        try await eventually(f.sensor.changes.stream) { f.sensor.rectWaiter != nil }
        f.snapshot(["heading", "🌷 quoted first phrase"], switching: false)
        try #require(f.sensor.rectWaiter).resume()
        f.sensor.rectWaiter = nil
        try await eventually(f.overlay.changes.stream) { f.overlay.narrations.count == 1 }
        #expect(f.overlay.narrations.first?.anchor?.minY == 180)
        #expect(f.sensor.ranges.last == NSRange(location: 10, length: 12))
        try f.finish()
    }

    @Test func switchingDuringGeometryNeverDisplaysOldMark() async throws {
        let f = try BrainFixture(), generator = BrainGenerator()
        f.sensor.pauseRect = true
        f.configure(generator)
        f.snapshot()
        try await eventually(generator.changes.stream) { await generator.prompts.count == 1 }
        await generator.complete(0, firstMark)
        try await eventually(f.sensor.changes.stream) { f.sensor.rectWaiter != nil }
        f.brain.windowChanged()
        try #require(f.sensor.rectWaiter).resume()
        f.sensor.rectWaiter = nil
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.overlay.narrations.isEmpty)
        try f.finish()
    }
}
