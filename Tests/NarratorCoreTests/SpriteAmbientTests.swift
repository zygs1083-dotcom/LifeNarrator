import Foundation
import Testing
@testable import NarratorCore

private struct AmbientStub: TextGenerator {
    let json: String
    var long = false
    func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?) async throws -> String {
        #expect(schema == (long ? SpriteAmbient.longSchema : SpriteAmbient.schema))
        #expect(maxTokens == 450)
        #expect(system != nil)
        return json
    }
}

private let ambientSignals = SpriteAmbientSignals(app: "Fixture", title: String(repeating: "题", count: 25),
    minutes: 23, hour: 14, minute: 5, switches: 7, typedRecently: true)

@Test func ambientPromptsUseLocalSignalsPersonaAndLengthRulesInBothLanguages() throws {
    #expect(ambientSignals.title.count == 20)
    for lang in Lang.allCases {
        let prompt = SpriteAmbient.prompt(signals: ambientSignals, persona: .sharp, lang: lang, recent: ["old aside"])
        #expect(prompt.system.contains(PersonaCatalog.builtin[.sharp].description[lang]))
        #expect(prompt.system.contains(lang == .zh ? "14 个汉字" : "8 words"))
        #expect(prompt.system.contains(lang == .zh ? "不要泛泛的鸡汤" : "never generic motivational advice"))
        #expect(prompt.system.contains(lang == .zh ? "不提屏幕上的具体文字" : "never mention specific screen text")
            || prompt.system.contains("or mention specific screen text"))
        for signal in ["Fixture", String(repeating: "题", count: 20), "23", "14:05", "7", "old aside"] {
            #expect(prompt.user.contains(signal))
        }
        #expect(!prompt.user.contains(String(repeating: "题", count: 21)))
        #expect(!prompt.system.contains("old aside"))
    }
    let schema = try JSONSerialization.jsonObject(with: Data(SpriteAmbient.schema.utf8)) as! [String: Any]
    let lines = (schema["properties"] as! [String: Any])["lines"] as! [String: Any]
    #expect(lines["minItems"] as? Int == 3)
    #expect(lines["maxItems"] as? Int == 6)
}

@Test func ambientGenerationValidatesTextEmojiAndBatchDuplicates() async throws {
    let json = #"{"lines":[{"t":"咖啡还没凉","e":"☕"},{"t":"咖啡还没凉！","e":"✨"},{"t":"键盘放个小假","e":"🌷"},{"t":"两个表情","e":"🌷✨"},{"t":"文字有🌷","e":"🌷"},{"t":"abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz","e":"🌷"}]}"#
    let lines = try await SpriteAmbient.generate(signals: ambientSignals, persona: .sharp, lang: .zh,
        recent: [], generator: AmbientStub(json: json))
    #expect(lines.map(\.text) == ["咖啡还没凉", "键盘放个小假"])
    #expect(lines.allSatisfy { $0.lang == .zh && $0.persona == .sharp && $0.emoji.count == 1 })
}

@Test func ambientGenerationSupportsLongPersonaAndRejectsMalformedOrWrongSizedBatches() async throws {
    let json = #"{"lines":[{"t":"咖啡还没凉","e":"☕"},{"t":"键盘放个小假","e":"🌷"},{"t":"窗口跳起踢踏舞","e":"💃"}]}"#
    let lines = try await SpriteAmbient.generate(signals: ambientSignals, persona: .teacher, lang: .zh,
        recent: [], generator: AmbientStub(json: json, long: true))
    #expect(lines.count == 3)
    await #expect(throws: SpriteAmbient.Failure.invalidBatchSize) {
        try await SpriteAmbient.generate(signals: ambientSignals, persona: .sharp, lang: .zh,
            recent: [], generator: AmbientStub(json: #"{"lines":[]}"#))
    }
    await #expect(throws: DecodingError.self) {
        try await SpriteAmbient.generate(signals: ambientSignals, persona: .sharp, lang: .zh,
            recent: [], generator: AmbientStub(json: #"{"lines":[{"t":"missing emoji"}]}"#))
    }
}

@Test func ambientCacheIsPerAppExpiresAfterTenMinutesAndConsumesPastSaidHistory() {
    var cache = SpriteAmbientCache()
    cache.store([quip("已经说过"), quip("咖啡还没凉"), quip("键盘放个小假")], app: "fixture", now: epoch)
    var said = SaidHistory()
    said.record("已经说过", now: epoch)
    let first = cache.take(app: "fixture", now: epoch.addingTimeInterval(1), isRepeat: { said.isRepeat($0, now: epoch) })
    #expect(first?.text == "咖啡还没凉")
    #expect(cache.take(app: "other", now: epoch, isRepeat: { _ in false }) == nil)
    #expect(cache.contains(app: "fixture", now: epoch.addingTimeInterval(599.999)))
    #expect(cache.take(app: "fixture", now: epoch.addingTimeInterval(599), isRepeat: { _ in false })?.text == "键盘放个小假")
    #expect(cache.take(app: "fixture", now: epoch.addingTimeInterval(599), isRepeat: { _ in false }) == nil)
    #expect(!cache.contains(app: "fixture", now: epoch.addingTimeInterval(599)))
    #expect(!cache.contains(app: "fixture", now: epoch.addingTimeInterval(600)))
    cache.store([quip("新句")], app: "fixture", now: epoch.addingTimeInterval(600))
    #expect(cache.take(app: "fixture", now: epoch.addingTimeInterval(600), isRepeat: { _ in false })?.text == "新句")
}
