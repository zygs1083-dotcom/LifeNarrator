import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import NarratorCore
@testable import NarratorBrain

private actor ChatGenerator: TextGenerator {
    var responses: [String]
    var prompts: [String] = []
    var systems: [String] = []
    init(_ responses: [String]) { self.responses = responses }
    func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?) async throws -> String {
        #expect(schema == ChatEngine.schema)
        systems.append(system!)
        prompts.append(prompt)
        return responses.removeFirst()
    }
}

private func response(_ intent: String = "chat", reply: String = "我在呢。", rule: String? = nil,
                      setting: [String: Any]? = nil, memories: [[String: String]] = [], forget: String? = nil) throws -> String {
    let value: [String: Any] = ["intent": intent, "reply": reply, "rule": rule as Any? ?? NSNull(),
        "setting": setting as Any? ?? NSNull(), "memories": memories, "forget": forget as Any? ?? NSNull()]
    return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
}

@MainActor private final class ChatSensor: BrainSensor {
    var secure = false
    func isTyping(now: Date) async throws -> Bool { false }
    func isSecureFocused() async throws -> Bool { secure }
    func idleSeconds() async -> TimeInterval { 0 }
    func lastTypedAt() async -> Date { .distantPast }
    func isLowPowerMode() async -> Bool { false }
    func refresh() async {}
    func boundsProbe() async throws -> Bool { true }
    func windowImage(windowID: UInt32, windowFrame: CGRect, redactions: [CGRect]) async throws -> Data { throw WindowImageError.windowUnavailable }
    func startVisualLines() async {}
    func textRect(lineIndex: Int, range: NSRange) async throws -> (rect: CGRect, kind: RectKind)? { nil }
    func markTrack(lineIndex: Int, kind: RectKind?) async throws -> String? { nil }
    func unframedRect(lineIndex: Int, range: NSRange) async -> CGRect { .zero }
    func placementLine(lineIndex: Int, rect: CGRect, kind: RectKind?) async -> CGRect { rect }
    func placementObstacles(in contentFrame: CGRect) async -> [CGRect] { [] }
}

@MainActor private final class ChatOverlay: BrainOverlay {
    func show(_ narration: Narration) async -> (shown: Bool, placement: String) { (true, "corner") }
    func dismissAll() async {}
    func follow() async {}
    func highlight(id: String) async -> CGRect? { nil }
    func windowFrameChanged(windowID: UInt32, window: WindowGeometry) async {}
}

@MainActor private final class ChatHost: BrainHost {
    var rules: [String] = []
    var settings: [ChatSetting] = []
    var failure = false
    func report(_ error: any Error) async { Issue.record("Unexpected host error: \(error)") }
    func saveRule(input: String) async throws {
        if failure { throw ChatEngine.Failure.invalidResponse }
        rules.append(input)
    }
    func applySetting(_ setting: ChatSetting) async throws { settings.append(setting) }
}

@MainActor private final class ChatFixture {
    let directory: URL
    let brain: SpriteBrain
    let host = ChatHost()
    let sensor = ChatSensor()
    var settings = BrainSettings(liveliness: .lively, markGap: 2, paused: false, blacklist: ["private"],
        persona: .gentle, lang: .zh, disabledBuiltinIds: [], maxOnScreen: 3, modelAvailable: true,
        systemOne: nil, ownProcessID: 999)
    let content = BrainContent(rules: [], builtin: QuipPack(version: 1, rules: [], generic: [:]), personas: .builtin)
    init() throws {
        directory = try memoryTestDirectory()
        brain = try SpriteBrain(sensor: sensor, overlay: ChatOverlay(), host: host, saidURL: directory.appendingPathComponent("said.json"))
    }
    func configure(_ generator: ChatGenerator?) {
        brain.configure(settings: settings, content: content, generator: .success(generator))
    }
}

@Suite(.serialized) @MainActor struct ChatEngineTests {
    @Test func executesAllIntentsMemoryNoticeAndExperience() async throws {
        let f = try ChatFixture()
        defer { try! FileManager.default.removeItem(at: f.directory) }
        let generator = ChatGenerator(try [
            response("rule", rule: "我讨厌开会"),
            response("setting", setting: ["liveliness": "quiet", "paused": true, "persona": "sharp"]),
            response("remember", memories: [["kind": "preference", "text": "你讨厌开会"]]),
            response("recall", reply: "你讨厌开会。"),
            response("forget", forget: "你讨厌开会"),
            response(),
            response("remember", memories: [["kind": "nickname", "text": "叫你阿王"]])
        ])
        f.configure(generator)
        let start = f.brain.growthState.experience
        for index in 0..<7 {
            let turn = try await f.brain.sendChat("第\(index)句", context: ChatContext())
            #expect((turn.notice != nil) == (index == 2))
            if index == 4 { #expect(f.brain.memories.isEmpty) }
        }
        #expect(f.host.rules == ["我讨厌开会"])
        #expect(f.host.settings == [ChatSetting(liveliness: .quiet, paused: true, persona: .sharp)])
        #expect(f.brain.memories.map(\.text) == ["叫你阿王"])
        #expect(f.brain.memories[0].source == .chat)
        #expect(f.brain.growthState.chatMessages == 7)
        // First active day +30, seven messages +70, two memories +10.
        #expect(f.brain.growthState.experience - start == 110)
        let prompts = await generator.prompts
        #expect(prompts[3].contains("你讨厌开会"))
        #expect(!prompts[5].contains("\"memories\":[\"你讨厌开会\"]"))
        let restored = try ChatEngine(url: f.directory.appendingPathComponent("chat.json"))
        #expect(restored.turns.count == 7)
        let next = ChatGenerator(try [response("remember", memories: [["kind": "fact", "text": "住在杭州"]])])
        let turn = try await restored.send("我住在杭州", context: ChatContext(), includeScreen: false, settings: f.settings,
            catalog: .builtin, memories: [], relationship: "已经熟了", generator: next, execute: { _ in true })
        #expect(turn.notice == nil)
    }

    @Test func historyKeepsLastFiftyAndPromptsOnlySixRecentTurns() async throws {
        let f = try ChatFixture()
        defer { try! FileManager.default.removeItem(at: f.directory) }
        let generator = ChatGenerator(try (0..<53).map { _ in try response() })
        for index in 0..<53 {
            _ = try await f.brain.chat.send("消息\(index)", context: ChatContext(), includeScreen: false,
                settings: f.settings, catalog: .builtin, memories: [], relationship: "刚认识，客气一点",
                generator: generator, execute: { _ in false })
        }
        let turns = try ChatEngine(url: f.directory.appendingPathComponent("chat.json")).turns
        #expect(turns.count == 50)
        #expect(turns.first?.user == "消息3")
        #expect(turns.last?.user == "消息52")
        let last = try #require(await generator.prompts.last)
        let prompt = try #require(try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any])
        #expect((prompt["conversation"] as? [Any])?.count == 6)
    }

    @Test func promptUsesPersonaRelationshipMemoriesAndExplicitScreenOptIn() async throws {
        let f = try ChatFixture()
        defer { try! FileManager.default.removeItem(at: f.directory) }
        let generator = ChatGenerator(try [response(), response()])
        f.configure(generator)
        _ = try f.brain.addMemory(kind: .fact, text: "住在杭州")
        let context = ChatContext(title: "周报", quotes: ["项目进展"], narration: "周报又来啦", screen: "仅显式附上的正文")
        _ = try await f.brain.sendChat("你好", context: context)
        _ = try await f.brain.sendChat("看看这页", context: context, includeScreen: true)
        let prompts = await generator.prompts
        let system = try #require(await generator.systems.first)
        #expect(system.contains(PersonaCatalog.builtin[.gentle].description.zh))
        #expect(system.contains("刚认识，客气一点"))
        for text in ["住在杭州", "周报", "项目进展", "周报又来啦"] { #expect(prompts[0].contains(text)) }
        #expect(!prompts[0].contains("仅显式附上的正文"))
        #expect(prompts[1].contains("仅显式附上的正文"))
        let disk = try String(contentsOf: f.directory.appendingPathComponent("chat.json"), encoding: .utf8)
        #expect(!disk.contains("仅显式附上的正文"))
        #expect(f.brain.memories.count == 1)
    }

    @Test func invalidResponsesAndHostFailuresDoNotRecordSuccessfulTurns() async throws {
        let f = try ChatFixture()
        defer { try! FileManager.default.removeItem(at: f.directory) }
        let generator = ChatGenerator(try [response(reply: String(repeating: "字", count: 41)),
            response("rule"), response("setting", setting: ["persona": "unknown"]),
            response(memories: [["kind": "episode", "text": "不能由聊天生成"]]),
            response("rule", rule: "我讨厌开会")])
        f.configure(generator)
        for _ in 0..<4 {
            await #expect(throws: (any Error).self) { try await f.brain.sendChat("你好", context: ChatContext()) }
        }
        f.host.failure = true
        await #expect(throws: (any Error).self) { try await f.brain.sendChat("学条规则", context: ChatContext()) }
        #expect(f.brain.chat.turns.isEmpty)
        #expect(f.brain.memories.isEmpty)
        #expect(f.brain.growthState.chatMessages == 0)
        f.configure(nil)
        await #expect(throws: ChatEngine.Failure.self) { try await f.brain.sendChat("你好", context: ChatContext()) }
    }

    @Test func englishWordLimitAndMemorySwitch() async throws {
        let f = try ChatFixture()
        defer { try! FileManager.default.removeItem(at: f.directory) }
        f.settings.lang = .en
        f.settings.memoryEnabled = false
        let generator = ChatGenerator(try [response(reply: Array(repeating: "word", count: 25).joined(separator: " "),
            memories: [["kind": "fact", "text": "Lives in Paris"]]),
            response(reply: Array(repeating: "word", count: 26).joined(separator: " "))])
        f.configure(generator)
        let turn = try await f.brain.sendChat("hello", context: ChatContext())
        #expect(turn.notice == nil)
        #expect(f.brain.memories.isEmpty)
        #expect(f.brain.growthState.chatMessages == 1)
        await #expect(throws: ChatEngine.Failure.self) { try await f.brain.sendChat("hello", context: ChatContext()) }
    }

    @Test nonisolated func chatMemoriesPrioritizePinnedThenRecentWithoutMarkBudget() throws {
        let directory = try memoryTestDirectory()
        defer { try! FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.json")
        let start = Date()
        var entries: [Memory] = []
        for index in 0..<24 {
            let text = String(repeating: String(UnicodeScalar(0x4E00 + index)!), count: 40)
            let date = start.addingTimeInterval(Double(index))
            entries.append(Memory(id: UUID(), kind: .fact, text: text, source: .manual,
                                  createdAt: date, lastUsedAt: date, uses: 0, pinned: index == 0))
        }
        try JSONEncoder().encode(entries).write(to: url)
        var store = try MemoryStore(url: url)
        let selected = try store.chat(now: start.addingTimeInterval(50))
        #expect(selected.count == 20)
        #expect(selected[0].pinned)
        #expect(selected[1].createdAt == start.addingTimeInterval(23))
        #expect(store.memories.filter { $0.uses == 1 }.count == 20)
    }

    @Test func chatScreenReusesMarkPrivacyAndExcludesBlacklistedOrSecureWindows() async throws {
        let f = try ChatFixture()
        defer { try! FileManager.default.removeItem(at: f.directory) }
        f.configure(nil)
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let snapshot = ContextSnapshot(bundleId: "browser", appName: "Browser", pid: 100, windowTitle: "Contact me@example.com", windowFrame: frame,
            contentFrame: frame, textLines: [
                TextLine(text: "联系 me@example.com 以及项目进展", rect: CGRect(x: 10, y: 100, width: 500, height: 20)),
                TextLine(text: "输入框里的秘密", rect: CGRect(x: 10, y: 150, width: 500, height: 20), role: .field)
            ], sensitiveRects: [], capturedAt: Date())
        let context = try await f.brain.chatContext(snapshot: snapshot)
        #expect(!context.title.contains("me@example.com"))
        #expect(!context.screen.contains("me@example.com"))
        #expect(!context.screen.contains("输入框里的秘密"))
        #expect(context.screen.contains("项目进展"))
        f.sensor.secure = true
        #expect(try await f.brain.chatContext(snapshot: snapshot).screen.isEmpty)
        f.sensor.secure = false
        f.settings.blacklist = ["browser"]
        f.configure(nil)
        #expect(try await f.brain.chatContext(snapshot: snapshot).title.isEmpty)
    }
}

@Test func chatSchemaCanBeSentToAPI() throws {
    let client = OpenAIChatClient(baseURL: URL(string: "http://127.0.0.1:18765/v1")!, path: "/chat/completions", model: "fixture", key: "")
    let request = try client.makeRequest(system: "companion", prompt: "hello", schema: ChatEngine.schema)
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    #expect(body["response_format"] != nil)
}
