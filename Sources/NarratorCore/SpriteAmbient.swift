import Foundation

public struct SpriteAmbientSignals: Sendable {
    public let app: String
    public let title: String
    public let minutes: Int
    public let hour: Int
    public let minute: Int
    public let switches: Int
    public let typedRecently: Bool

    public init(app: String, title: String, minutes: Int, hour: Int, minute: Int,
                switches: Int, typedRecently: Bool) {
        self.app = app
        self.title = String(title.prefix(20))
        self.minutes = minutes
        self.hour = hour
        self.minute = minute
        self.switches = switches
        self.typedRecently = typedRecently
    }
}

public enum SpriteAmbient {
    public enum Failure: Error { case invalidBatchSize }

    public static let schema = #"""
    {"type":"object","required":["lines"],"additionalProperties":false,"properties":{"lines":{"type":"array","minItems":3,"maxItems":6,"items":{"type":"object","required":["t","e"],"additionalProperties":false,"properties":{"t":{"type":"string","minLength":1,"maxLength":56},"e":{"type":"string"}}}}}}
    """#
    public static let longSchema = schema.replacingOccurrences(of: "\"maxLength\":56", with: "\"maxLength\":80")

    public static func prompt(signals: SpriteAmbientSignals, persona: Persona, lang: Lang,
                              recent: [String], catalog: PersonaCatalog = .builtin) -> (system: String, user: String) {
        let profile = catalog[persona]
        let system: String
        let user: String
        if lang == .zh {
            system = """
            你是 LifeNarrator，一只住在用户电脑里的旁白小精灵。
            人设：\(profile.description.zh)
            写 3–6 句不圈字的角落旁白。说当下的状态，不要泛泛的鸡汤，不说教、不编造事实、不提屏幕上的具体文字。窗口标题只是场景线索，不要引用或改写标题。
            像朋友随口一句，几句的角度、开头和梗要不同。每句不超过 \(profile.limit.zh) 个汉字（标点算字），文字里不写表情；e 是一个表情。
            只输出 JSON：{"lines":[{"t":"旁白","e":"表情"}]}。
            """
            user = """
            应用：\(signals.app)
            窗口标题（最多20字）：\(signals.title)
            今天在此应用累计：\(signals.minutes) 分钟
            现在：\(signals.hour):\(String(format: "%02d", signals.minute))
            最近10分钟切窗口：\(signals.switches) 次
            最近1分钟打过字：\(signals.typedRecently ? "是" : "否")
            最近说过（别重复句式和梗）：\(recent.prefix(8).joined(separator: " / "))
            """
        } else {
            system = """
            You are LifeNarrator, a tiny narrator sprite living in the user's computer.
            Persona: \(profile.description.en)
            Write 3–6 corner asides without highlighting text. Remark on the present state, never generic motivational advice. Never preach, invent facts or mention specific screen text. The window title is a scene hint only: never quote or paraphrase it.
            Sound like a friend speaking casually. Vary the angles, openings and jokes. Each line under \(profile.limit.en) words, no emoji in text; e is exactly one emoji.
            Output JSON only: {"lines":[{"t":"aside","e":"emoji"}]}.
            """
            user = """
            App: \(signals.app)
            Window title (at most 20 characters): \(signals.title)
            Minutes in this app today: \(signals.minutes)
            Time now: \(signals.hour):\(String(format: "%02d", signals.minute))
            Window switches in the last 10 minutes: \(signals.switches)
            Typed in the last minute: \(signals.typedRecently ? "yes" : "no")
            Recently said (avoid their phrasing and jokes): \(recent.prefix(8).joined(separator: " / "))
            """
        }
        return (system, user)
    }

    public static func generate(signals: SpriteAmbientSignals, persona: Persona, lang: Lang,
                                recent: [String], generator: any TextGenerator,
                                catalog: PersonaCatalog = .builtin) async throws -> [Quip] {
        struct Line: Decodable { let t: String; let e: String }
        struct Batch: Decodable { let lines: [Line] }
        let prompt = prompt(signals: signals, persona: persona, lang: lang, recent: recent, catalog: catalog)
        let json = try await generator.generateJSON(system: prompt.system, prompt: prompt.user,
            schema: catalog[persona].limit.en > 8 ? longSchema : schema, maxTokens: 450)
        let batch = try JSONDecoder().decode(Batch.self, from: Data(json.utf8))
        guard (3...6).contains(batch.lines.count) else { throw Failure.invalidBatchSize }
        let limit = SpriteGenerator.spriteLimit(persona: persona, catalog: catalog)
        var said = SaidHistory()
        return batch.lines.compactMap { line in
            let text = line.t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= (lang == .zh ? limit.zh : limit.en),
                  !text.contains(where: QuipValidator.isEmoji), line.e.count == 1,
                  QuipValidator.isEmoji(line.e.first!),
                  text.range(of: "\\{[^{}]*\\}", options: .regularExpression) == nil,
                  !said.isRepeat(text, now: Date()) else { return nil }
            said.record(text, now: Date())
            return Quip(lang: lang, persona: persona, text: text, emoji: [line.e])
        }
    }
}

public struct SpriteAmbientCache: Sendable {
    private struct Batch: Sendable { let created: Date; var lines: [Quip] }
    private var apps: [String: Batch] = [:]
    public init() {}

    public func contains(app: String, now: Date) -> Bool {
        apps[app].map { now.timeIntervalSince($0.created) < 600 && !$0.lines.isEmpty } == true
    }

    public mutating func store(_ lines: [Quip], app: String, now: Date) {
        apps = apps.filter { now.timeIntervalSince($0.value.created) < 600 }
        apps[app] = Batch(created: now, lines: lines)
    }

    public mutating func take(app: String, now: Date, isRepeat: (String) -> Bool) -> Quip? {
        guard contains(app: app, now: now) else { return nil }
        while !apps[app]!.lines.isEmpty {
            let line = apps[app]!.lines.removeFirst()
            if !isRepeat(line.text) { return line }
        }
        return nil
    }
}
