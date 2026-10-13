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
        #expect(maxTokens == 450)
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

private func generateSprite(_ json: String, texts: [String] = ["quoted first phrase", "another second phrase", "last third phrase"],
                            lang: Lang = .zh, k: Int = 3, stream: Bool = false, fail: Bool = false,
                            recorder: MarkRecorder = MarkRecorder()) async throws -> [SpriteMark] {
    let snapshot = semanticsSnapshot(texts)
    return try await SpriteGenerator.generate(screen: SpritePrompt.screen(in: snapshot), snapshot: snapshot,
        app: "Fixture", title: "Manual", exclude: ["previous"], persona: .gentle, lang: lang, k: k,
        generator: SpriteStub(response: json, stream: stream, failAfterFirst: fail, afterPartial: { count in
            #expect(recorder.marks.count == count)
        }), onMark: { recorder.append($0) })
}

private let validMarksJSON = #"{"marks":[{"l":0,"q":"first phrase","t":"第一句","e":"🌷"},{"l":1,"q":"second phrase","t":"第二句","e":"🌷"},{"l":2,"q":"third phrase","t":"第三句","e":"🌷"}]}"#

@Test func spriteGenerationStreamsThreeMarksInOrderExactlyOnce() async throws {
    let recorder = MarkRecorder()
    let marks = try await generateSprite(validMarksJSON, stream: true, recorder: recorder)
    #expect(marks.map(\.lineIndex) == [0, 1, 2])
    #expect(recorder.marks.map(\.quote) == ["first phrase", "second phrase", "third phrase"])
    #expect(marks.map(\.quip.text) == ["第一句", "第二句", "第三句"])
}

@Test func spriteGenerationAPIAndDefaultProtocolImplementationReturnAllMarks() async throws {
    let marks = try await generateSprite(validMarksJSON)
    #expect(marks.count == 3)
    struct APIStub: TextGenerator {
        func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?) async throws -> String { validMarksJSON }
    }
    let snapshot = semanticsSnapshot(["first phrase", "second phrase", "third phrase"])
    let result = try await SpriteGenerator.generate(screen: SpritePrompt.screen(in: snapshot), snapshot: snapshot,
        app: "Fixture", title: "", exclude: [], persona: .gentle, lang: .zh, k: 3, generator: APIStub(), onMark: { _ in })
    #expect(result.count == 3)
}

@Test func spriteGenerationDropsInvalidBoundsQuotesQuipsEmojiOverlapsAndExcess() async throws {
    let raw: [[String: Any]] = [
        ["l":99,"q":"first phrase","t":"越界","e":"🌷"],
        ["l":0,"q":"missing phrase","t":"找不到","e":"🌷"],
        ["l":0,"q":"first phrase","t":String(repeating:"字",count:15),"e":"🌷"],
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
        let limit = lang == .zh ? 14 : 40
        for (text, emoji, quote) in [("", "🌷", "first phrase"), ("文字🌷", "🌷", "first phrase"), ("{text}", "🌷", "first phrase"),
                                    (String(repeating: "x", count: limit + 1), "🌷", "first phrase"),
                                    ("台词", "1", "first phrase"), ("台词", "🌷", "f"), ("台词", "🌷", String(repeating: "x", count: 33))] {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: ["marks": [["l":0,"q":quote,"t":text,"e":emoji]]]), as: UTF8.self)
            #expect(try await generateSprite(json, lang: lang).isEmpty)
        }
    }
    #expect(try await generateSprite(#"{"marks":[{"l":0,"q":"***","t":"隐私","e":"🌷"}]}"#, texts: ["Email alice@example.com checked"]).isEmpty)
    let snapshot = semanticsSnapshot(["first phrase alice@example.com", "second phrase"])
    // Deliberately bypass prompt filtering to exercise the output boundary checks.
    let screen = SpriteScreen(lines: [(0, snapshot.textLines[0].text), (1, snapshot.textLines[1].text)], tokens: 10)
    var sensitive = snapshot
    sensitive.sensitiveRects = [snapshot.textLines[1].rect]
    let marks = try await SpriteGenerator.generate(screen: screen, snapshot: sensitive, app: "Fixture", title: "", exclude: [],
        persona: .gentle, lang: .zh, k: 3, generator: SpriteStub(response: #"{"marks":[{"l":0,"q":"alice@example.com","t":"隐私","e":"🌷"},{"l":1,"q":"second phrase","t":"密码","e":"🌷"}]}"#), onMark: { _ in })
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
    var snapshot = semanticsSnapshot(["draft phrase", "prefix ＨＥＬＬＯ   World suffix", "another phrase"])
    snapshot.textLines[0].role = .field
    let result = try await SpriteGenerator.generate(screen: SpritePrompt.screen(in: snapshot), snapshot: snapshot,
        app: "Fixture", title: "", exclude: [], persona: .gentle, lang: .zh, k: 3,
        generator: SpriteStub(response: #"{"marks":[{"l":0,"q":"hello world","t":"第一句","e":"🌷"},{"l":0,"q":"another phrase","t":"第二句","e":"🌷"},{"l":1,"q":"draft phrase","t":"不该有","e":"🌷"}]}"#), onMark: { _ in })
    #expect(result.map(\.lineIndex) == [1, 2])
    #expect(result.map(\.quote) == ["ＨＥＬＬＯ   World", "another phrase"])
    for mark in result { #expect(String(snapshot.textLines[mark.lineIndex].text[mark.range]) == mark.quote) }
}

@Test func spriteGenerationAcceptsExactLanguageLimitsAndEmptyBatches() async throws {
    for lang in Lang.allCases {
        let text = String(repeating: lang == .zh ? "字" : "x", count: lang == .zh ? 14 : 40)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["marks": [["l":0,"q":"first phrase","t":text,"e":"🌷"]]]), as: UTF8.self)
        #expect(try await generateSprite(json, lang: lang).first?.quip.text == text)
    }
    #expect(try await generateSprite(#"{"marks":[]}"#).isEmpty)
}
