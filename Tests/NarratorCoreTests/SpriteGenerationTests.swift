import Foundation
import Testing
@testable import NarratorCore

private struct SpriteStub: TextGenerator {
    var response: String
    var stream = false
    var failAfterFirst = false
    var afterPartial: @Sendable (Int) -> Void = { _ in }
    enum Failure: Error { case generationLimit }
    func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?) async throws -> String {
        #expect(system != nil)
        #expect(maxTokens == 900)
        #expect(schema == GenerationPrompts.spriteMarksSchema)
        return response
    }
    func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?,
                      partial: @escaping @Sendable (String) -> Bool) async throws -> String {
        _ = try await generateJSON(system: system, prompt: prompt, schema: schema, maxTokens: maxTokens)
        if stream {
            let parts = response.components(separatedBy: "},")
            var accumulated = ""
            for (i, part) in parts.enumerated() {
                accumulated += part + (i < parts.count - 1 ? "}," : "")
                #expect(partial(accumulated))
                afterPartial(i + 1)
                if failAfterFirst { throw Failure.generationLimit }
            }
        }
        return response
    }
}

private final class MarkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SpriteMark] = []
    func append(_ mark: SpriteMark) { lock.withLock { values.append(mark) } }
    var marks: [SpriteMark] { lock.withLock { values } }
}

private func generationSnapshot(_ texts: [String]) -> ContextSnapshot {
    var snapshot = semanticsSnapshot(texts)
    for i in snapshot.textLines.indices { snapshot.textLines[i].rect.origin.y = CGFloat(100 + i * 32) }
    return snapshot
}

private func generateSprite(_ json: String, texts: [String] = ["quoted first phrase", "another second phrase", "last third phrase"],
                            lang: Lang = .zh, k: Int = 3, stream: Bool = false, fail: Bool = false,
                            recorder: MarkRecorder = MarkRecorder()) async throws -> [SpriteMark] {
    let snapshot = generationSnapshot(texts)
    return try await SpriteGenerator.generate(screen: SpritePrompt.screen(in: snapshot), snapshot: snapshot,
        app: "Fixture", title: "Manual", exclude: ["previous"], persona: .gentle, lang: lang, k: k,
        generator: SpriteStub(response: json, stream: stream, failAfterFirst: fail, afterPartial: { count in
            #expect(recorder.marks.count == count)
        }), isRepeat: { _ in false }, onMark: { recorder.append($0) })
}

private let validMarksJSON = #"{"marks":[{"l":0,"q":"first phrase","t":"第一句","e":"🌷"},{"l":1,"q":"second phrase","t":"第二句","e":"🌷"},{"l":2,"q":"third phrase","t":"第三句","e":"🌷"}]}"#

@Test func spriteGenerationStreamsThreeMarksInOrderExactlyOnce() async throws {
    let recorder = MarkRecorder()
    let marks = try await generateSprite(validMarksJSON, stream: true, recorder: recorder)
    #expect(marks.map(\.lineIndex) == [0, 1, 2])
    #expect(recorder.marks.map(\.quote) == ["first phrase", "second phrase", "third phrase"])
    #expect(marks.map(\.quip.text) == ["第一句", "第二句", "第三句"])
}

@Test func spriteGenerationAcceptsEightMarksAndHonorsRequestCount() async throws {
    let texts = (0..<8).map { "quoted phrase \($0)" }
    let quips = ["咖啡还没凉", "谁偷偷请了假", "知识列车进站", "钱包快躲起来", "小苗雨天备案", "备用能量耗尽", "双脚放个假吧", "酵母闭关修炼"]
    let raw = (0..<8).map { ["l": $0, "q": texts[$0], "t": quips[$0], "e": "🌷"] as [String: Any] }
    let json = String(decoding: try JSONSerialization.data(withJSONObject: ["marks": raw]), as: UTF8.self)
    let recorder = MarkRecorder()
    let marks = try await generateSprite(json, texts: texts, k: 8, stream: true, recorder: recorder)
    #expect(marks.map(\.lineIndex) == Array(0..<8))
    #expect(recorder.marks.map(\.quote) == texts)
    #expect(try await generateSprite(json, texts: texts, k: 5).count == 5)
}

@Test func spriteGenerationAPIAndDefaultProtocolImplementationReturnAllMarks() async throws {
    let marks = try await generateSprite(validMarksJSON)
    #expect(marks.count == 3)
    struct APIStub: TextGenerator {
        func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?) async throws -> String { validMarksJSON }
    }
    let snapshot = generationSnapshot(["first phrase", "second phrase", "third phrase"])
    let result = try await SpriteGenerator.generate(screen: SpritePrompt.screen(in: snapshot), snapshot: snapshot,
        app: "Fixture", title: "", exclude: [], persona: .gentle, lang: .zh, k: 3, generator: APIStub(), isRepeat: { _ in false }, onMark: { _ in })
    #expect(result.count == 3)
}

@Test func spriteGenerationDropsInvalidBoundsQuotesQuipsEmojiOverlapsAndExcess() async throws {
    let raw: [[String: Any]] = [
        ["l":99,"q":"first phrase","t":"越界","e":"🌷"],
        ["l":0,"q":"missing phrase","t":"找不到","e":"🌷"],
        ["l":0,"q":"first phrase","t":String(repeating:"字",count:SpriteGenerator.spriteLimit(persona: .sharp).zh + 1),"e":"🌷"],
        ["l":0,"q":"first phrase","t":"两个表情","e":"🌷🌷"],
        ["l":0,"q":"first phrase","t":"第一句，、；：","e":"👨‍👩‍👧‍👦"],
        ["l":0,"q":"phrase","t":"重叠","e":"🌷"],
        ["l":1,"q":"second phrase","t":"第二句","e":"🌷"],
        ["l":2,"q":"third phrase","t":"超过数量","e":"🌷"]
    ]
    let json = String(decoding: try JSONSerialization.data(withJSONObject: ["marks": raw]), as: UTF8.self)
    let marks = try await generateSprite(json, k: 2)
    #expect(marks.map(\.quip.text) == ["第一句", "第二句"])
    #expect(marks[0].quip.emoji == ["👨‍👩‍👧‍👦"])
}

@Test func spriteGenerationRejectsTextAndQuoteLimitsAndPrivacy() async throws {
    for lang in Lang.allCases {
        let limit = lang == .zh ? SpriteGenerator.spriteLimit(persona: .sharp).zh : SpriteGenerator.spriteLimit(persona: .sharp).en
        for (text, emoji, quote) in [("", "🌷", "first phrase"), ("文字🌷", "🌷", "first phrase"), ("{text}", "🌷", "first phrase"),
                                    (String(repeating: "x", count: limit + 1), "🌷", "first phrase"),
                                    ("台词", "1", "first phrase"), ("台词", "🌷", "f"), ("台词", "🌷", String(repeating: "x", count: 33))] {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: ["marks": [["l":0,"q":quote,"t":text,"e":emoji]]]), as: UTF8.self)
            #expect(try await generateSprite(json, lang: lang).isEmpty)
        }
    }
    #expect(try await generateSprite(#"{"marks":[{"l":0,"q":"***","t":"隐私","e":"🌷"}]}"#, texts: ["Email alice@example.com checked"]).isEmpty)
    let snapshot = generationSnapshot(["first phrase alice@example.com", "second phrase"])
    // Deliberately bypass prompt filtering to exercise the output boundary checks.
    let screen = SpriteScreen(lines: [(0, snapshot.textLines[0].text), (1, snapshot.textLines[1].text)], tokens: 10)
    var sensitive = snapshot
    sensitive.sensitiveRects = [snapshot.textLines[1].rect]
    let marks = try await SpriteGenerator.generate(screen: screen, snapshot: sensitive, app: "Fixture", title: "", exclude: [],
        persona: .gentle, lang: .zh, k: 3, generator: SpriteStub(response: #"{"marks":[{"l":0,"q":"alice@example.com","t":"隐私","e":"🌷"},{"l":1,"q":"second phrase","t":"密码","e":"🌷"}]}"#), isRepeat: { _ in false }, onMark: { _ in })
    #expect(marks.isEmpty)
}

@Test func spriteGenerationKeepsAlreadyEmittedMarksWhenGenerationFails() async {
    let recorder = MarkRecorder()
    await #expect(throws: SpriteStub.Failure.self) {
        try await generateSprite(validMarksJSON, stream: true, fail: true, recorder: recorder)
    }
    #expect(recorder.marks.map(\.quote) == ["first phrase"])
    await #expect(throws: DecodingError.self) { try await generateSprite(#"{"marks":[{"l":0}]}"#) }
}

@Test func spriteGenerationMapsFilteredRowsAndWrongHintsBackToOriginalText() async throws {
    var snapshot = generationSnapshot(["draft phrase", "prefix ＨＥＬＬＯ   World suffix", "another phrase"])
    snapshot.textLines[0].role = .field
    let result = try await SpriteGenerator.generate(screen: SpritePrompt.screen(in: snapshot), snapshot: snapshot,
        app: "Fixture", title: "", exclude: [], persona: .gentle, lang: .zh, k: 3,
        generator: SpriteStub(response: #"{"marks":[{"l":0,"q":"hello world","t":"第一句","e":"🌷"},{"l":0,"q":"another phrase","t":"第二句","e":"🌷"},{"l":1,"q":"draft phrase","t":"不该有","e":"🌷"}]}"#), isRepeat: { _ in false }, onMark: { _ in })
    #expect(result.map(\.lineIndex) == [1, 2])
    #expect(result.map(\.quote) == ["ＨＥＬＬＯ   World", "another phrase"])
    for mark in result { #expect(String(snapshot.textLines[mark.lineIndex].text[mark.range]) == mark.quote) }
}

@Test func spriteGenerationAcceptsExactLanguageLimitsAndEmptyBatches() async throws {
    for lang in Lang.allCases {
        let text = String(repeating: lang == .zh ? "字" : "x", count: lang == .zh ? SpriteGenerator.spriteLimit(persona: .sharp).zh : SpriteGenerator.spriteLimit(persona: .sharp).en)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["marks": [["l":0,"q":"first phrase","t":text,"e":"🌷"]]]), as: UTF8.self)
        #expect(try await generateSprite(json, lang: lang).first?.quip.text == text)
    }
    #expect(try await generateSprite(#"{"marks":[]}"#).isEmpty)
}

@Test func spriteGenerationSpreadsPicksAcrossRowsAndDropsNearbyRows() async throws {
    let snapshot = semanticsSnapshot(["first quote and other words", "second quote", "third quote"])
    let json = #"{"marks":[{"l":0,"q":"first quote","t":"第一句","e":"🌷"},{"l":0,"q":"other words","t":"同行","e":"🌷"},{"l":1,"q":"second quote","t":"太近","e":"🌷"},{"l":2,"q":"third quote","t":"够远","e":"🌷"}]}"#
    let marks = try await SpriteGenerator.generate(screen: SpritePrompt.screen(in: snapshot), snapshot: snapshot,
        app: "Fixture", title: "", exclude: [], persona: .gentle, lang: .zh, k: 4,
        generator: SpriteStub(response: json), isRepeat: { _ in false }, onMark: { _ in })
    #expect(marks.map(\.quote) == ["first quote", "third quote"])
}

@Test func spriteGenerationDropsGlobalAndBatchRepeatsWithoutUsingSlots() async throws {
    for streaming in [false, true] {
        let snapshot = generationSnapshot(["first quote", "second quote", "third quote", "fourth quote", "fifth quote"])
        let json = #"{"marks":[{"l":0,"q":"first quote","t":"咖啡还没凉","e":"☕"},{"l":0,"q":"first quote","t":"昨晚星星睡着了","e":"🌷"},{"l":1,"q":"second quote","t":"昨晚星星睡着啦","e":"⭐"},{"l":2,"q":"third quote","t":"昨晚星星睡着了！","e":"😴"},{"l":3,"q":"fourth quote","t":"钱包快躲起来","e":"💸"},{"l":4,"q":"fifth quote","t":"小苗雨天备案","e":"🌱"}]}"#
        let recorder = MarkRecorder()
        let marks = try await SpriteGenerator.generate(screen: SpritePrompt.screen(in: snapshot), snapshot: snapshot,
            app: "Fixture", title: "", exclude: [], persona: .gentle, lang: .zh, k: 3,
            generator: SpriteStub(response: json, stream: streaming),
            isRepeat: { $0 == "咖啡还没凉" }, onMark: { recorder.append($0) })
        #expect(marks.map(\.quip.text) == ["昨晚星星睡着了", "钱包快躲起来", "小苗雨天备案"])
        #expect(recorder.marks.map(\.lineIndex) == [0, 3, 4])
    }
}

@Test func spriteGenerationCombinesCustomCatalogRecentAndRepeatFilter() async throws {
    struct CatalogStub: TextGenerator {
        let focus: String
        func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?) async throws -> String {
            #expect(system!.contains(focus))
            #expect(system!.contains("不超过 22 个汉字"))
            #expect(schema == GenerationPrompts.spriteMarksLongSchema)
            #expect(prompt.hasPrefix("最多 2 处。\n"))
            #expect(prompt.hasSuffix("最近说过的话（别再用一样的句式、开头和梗）：「older remark」"))
            return "{\"marks\":[{\"l\":0,\"q\":\"first phrase\",\"t\":\"旧句\",\"e\":\"🌷\"},{\"l\":1,\"q\":\"second phrase\",\"t\":\""
                + String(repeating: "字", count: 26) + "\",\"e\":\"🌷\"}]}"
        }
    }
    var profile = PersonaCatalog.builtin[.teacher]
    profile.id = Persona(rawValue: "custom.generation")
    profile.examples = .chuuni
    let snapshot = generationSnapshot(["first phrase", "second phrase"])
    let marks = try await SpriteGenerator.generate(screen: SpritePrompt.screen(in: snapshot), snapshot: snapshot,
        app: "A", title: "T", exclude: [], persona: profile.id, lang: .zh, k: 2, recent: ["older remark"],
        generator: CatalogStub(focus: profile.focus!.zh), catalog: PersonaCatalog(custom: [profile]),
        isRepeat: { $0 == "旧句" }, onMark: { _ in })
    #expect(marks.count == 1)
    #expect(marks.first?.quip.text.count == 26)
    #expect(marks.first?.quip.persona == profile.id)
}
