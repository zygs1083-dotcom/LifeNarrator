import Foundation
import Testing
import NarratorCore
@testable import NarratorBrain

private actor BrainGenerator: TextGenerator {
    var prompts: [String] = []
    var cancelled: Set<Int> = []
    private var pending: [Int: CheckedContinuation<String, any Error>] = [:]

    func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?) async throws -> String {
        let id = prompts.count
        prompts.append(prompt)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending[id] = $0 }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func complete(_ id: Int, _ json: String) { pending.removeValue(forKey: id)!.resume(returning: json) }
    private func cancel(_ id: Int) {
        cancelled.insert(id)
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

@MainActor private final class BrainTestSensor: BrainSensor {
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
            await withCheckedContinuation { rectWaiter = $0 }
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
    var narrations: [Narration] = []
    var dismissals = 0
    var pauseNext = false
    var showCalls = 0
    var showWaiter: CheckedContinuation<Void, Never>?
    func show(_ narration: Narration) async -> (shown: Bool, placement: String) {
        showCalls += 1
        if pauseNext {
            pauseNext = false
            await withCheckedContinuation { showWaiter = $0 }
        }
        narrations.append(narration)
        return (true, "right")
    }
    func dismissAll() async { dismissals += 1 }
    func follow() async {}
    func highlight(id: String) async -> CGRect? { narrations.first { $0.id == id }?.anchor }
    func windowFrameChanged(windowID: UInt32, window: WindowGeometry) async {}
}

@MainActor private final class BrainTestHost: BrainHost {
    var errors: [String] = []
    func report(_ error: any Error) async { errors.append(String(describing: error)) }
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

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        saidURL = directory.appendingPathComponent("said.json")
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

@MainActor private func eventually(seconds: TimeInterval = 3, _ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !(await condition()) && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(await condition())
}

private let firstMark = #"{"marks":[{"l":0,"q":"first phrase","t":"咖啡还没凉","e":"🌷"}]}"#

@Suite(.serialized) @MainActor struct SpriteBrainScenarios {
    @Test func contentUpdatesKeepRequestAndLocateAgainstLatestLines() async throws {
        let f = try BrainFixture(), generator = BrainGenerator()
        f.configure(generator)
        f.snapshot()
        try await eventually { await generator.prompts.count == 1 }
        f.snapshot(["unrelated heading", "quoted first phrase"], switching: false)
        #expect(await generator.cancelled.isEmpty)
        await generator.complete(0, firstMark)
        try await eventually { f.overlay.narrations.count == 1 }
        let narration = try #require(f.overlay.narrations.first)
        #expect(narration.windowID == 1)
        #expect(narration.trackID == "track-1")
        #expect(narration.anchor?.minY == 180)
        let history = try JSONDecoder().decode(SaidHistory.self, from: Data(contentsOf: f.saidURL))
        #expect(history.isRepeat("咖啡还没凉", now: Date()))
        try f.finish()
    }

    @Test func switchingCancelsRequestAndStartsForNewWindow() async throws {
        let f = try BrainFixture(), generator = BrainGenerator()
        f.configure(generator)
        f.snapshot()
        try await eventually { await generator.prompts.count == 1 }
        f.snapshot(window: 2)
        try await eventually { let cancelled = await generator.cancelled.contains(0)
            let count = await generator.prompts.count
            return cancelled && count == 2 }
        await generator.complete(1, firstMark)
        try await eventually { f.overlay.narrations.count == 1 }
        #expect(f.overlay.narrations.first?.windowID == 2)
        try f.finish()
    }

    @Test func typingDefersDisplayUntilTypingStops() async throws {
        let f = try BrainFixture(), generator = BrainGenerator()
        f.sensor.typing = true
        f.configure(generator)
        f.snapshot()
        try await eventually { await generator.prompts.count == 1 }
        await generator.complete(0, firstMark)
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.overlay.narrations.isEmpty)
        f.sensor.typing = false
        try await eventually { f.overlay.narrations.count == 1 }
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
        try await eventually { await generator.prompts.count == 1 }
        await generator.complete(0, #"{"marks":[{"l":1,"q":"first phrase","t":"咖啡还没凉","e":"🌷"}]}"#)
        try await Task.sleep(for: .milliseconds(100))
        f.sensor.typing = false
        try await eventually { f.overlay.showWaiter != nil }
        try await Task.sleep(for: .milliseconds(300))
        #expect(f.overlay.showCalls == 1)
        try #require(f.overlay.showWaiter).resume()
        f.overlay.showWaiter = nil
        try await eventually { f.overlay.narrations.count == 1 }
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
        try await eventually { await generator.prompts.count == 1 }
        await generator.complete(0, firstMark)
        try await eventually { await generator.prompts.count == 2 }
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
        try await eventually { await idleGenerator.prompts.count == 1 }
        await idleGenerator.complete(0, #"{"marks":[]}"#)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(await idleGenerator.prompts.count == 1)
        idle.sensor.idle = 0
        try await eventually { await idleGenerator.prompts.count == 2 }
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
        try await eventually { f.overlay.narrations.count == 1 }
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
        try await eventually { !f.host.errors.isEmpty }
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
        try await eventually { f.overlay.narrations.count == 1 }
        #expect(f.host.errors.isEmpty)
        rule.id = "topic"
        rule.kind = .topic
        rule.match = Match(aliases: ["first phrase"])
        f.content.rules = [rule]
        f.configure()
        f.snapshot(window: 2)
        try await eventually { !f.host.errors.isEmpty }
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
        try await eventually { await generator.prompts.count == 1 }
        await generator.complete(0, firstMark)
        try await eventually { f.sensor.rectWaiter != nil }
        f.snapshot(["heading", "🌷 quoted first phrase"], switching: false)
        try #require(f.sensor.rectWaiter).resume()
        f.sensor.rectWaiter = nil
        try await eventually { f.overlay.narrations.count == 1 }
        #expect(f.overlay.narrations.first?.anchor?.minY == 180)
        #expect(f.sensor.ranges.last == NSRange(location: 10, length: 12))
        try f.finish()
    }

    @Test func switchingDuringGeometryNeverDisplaysOldMark() async throws {
        let f = try BrainFixture(), generator = BrainGenerator()
        f.sensor.pauseRect = true
        f.configure(generator)
        f.snapshot()
        try await eventually { await generator.prompts.count == 1 }
        await generator.complete(0, firstMark)
        try await eventually { f.sensor.rectWaiter != nil }
        f.brain.windowChanged()
        try #require(f.sensor.rectWaiter).resume()
        f.sensor.rectWaiter = nil
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.overlay.narrations.isEmpty)
        try f.finish()
    }
}
