import Foundation
import Testing
@testable import NarratorCore

private struct SpriteStub: TextGenerator {
    var response: String
    func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?) async throws -> String {
        #expect(system == nil)
        #expect(maxTokens == 320)
        #expect(schema == GenerationPrompts.spriteMarksSchema)
        #expect(prompt.contains("0. [money] ¥1,299.00"))
        return response
    }
}

private let spriteTargets: [(category: String, text: String)] = [
    ("money", "¥1,299.00"), ("deadline", "截止周五 18:00 前提交"), ("name", "张三"), ("alert", "构建失败：3 个错误")
]
private func generateSprite(_ json: String, lang: Lang = .zh) async throws -> (quips: [Int: Quip], declined: Set<Int>) {
    try await SpriteGenerator.generate(targets: spriteTargets, app: "Fixture", title: "Feed", persona: .gentle,
                                       lang: lang, generator: SpriteStub(response: json))
}

@Test func spriteGenerationDropsInvalidAndDuplicateIndices() async throws {
    let result = try await generateSprite(#"{"marks":[{"i":-1,"text":"负序号","emoji":["🌷"]},{"i":8,"text":"超范围","emoji":["🌷"]},{"i":4,"text":"非候选","emoji":["🌷"]},{"i":0,"text":"第一句","emoji":["🌷"]},{"i":0,"text":"重复句","emoji":["🌷"]},{"i":1,"text":"一二三四五六七八九十一二三四五","emoji":["🌷"]}]}"#)
    #expect(result.quips == [0: Quip(lang: .zh, persona: .gentle, text: "第一句", emoji: ["🌷"])])
    #expect(result.declined == [1, 2, 3])
}

@Test func spriteGenerationAllowsSingleQuipAndTrimsPunctuation() async throws {
    let result = try await generateSprite(#"{"marks":[{"i":2,"text":"  慢慢聊，、；：  \n","emoji":["👨‍👩‍👧‍👦"]}]}"#)
    #expect(result.quips[2]?.text == "慢慢聊")
    #expect(result.quips[2]?.emoji == ["👨‍👩‍👧‍👦"])
    #expect(result.declined == [0, 1, 3])
}

@Test func spriteGenerationEmptyBatchDeclinesAll() async throws {
    let result = try await generateSprite(#"{"marks":[]}"#)
    #expect(result.quips.isEmpty)
    #expect(result.declined == [0, 1, 2, 3])
}

@Test func spriteGenerationKeepsFirstIndexEvenIfFirstTextIsInvalid() async throws {
    let result = try await generateSprite(#"{"marks":[{"i":0,"text":"","emoji":["🌷"]},{"i":0,"text":"第二句","emoji":["🌷"]}]}"#)
    #expect(result.quips.isEmpty)
    #expect(result.declined == [0, 1, 2, 3])
}

@Test func spriteGenerationRejectsInvalidTextAndEmoji() async throws {
    for (text, emoji) in [(" ", ["🌷"]), ("，、；：", ["🌷"]), ("文字🌷", ["🌷"]), ("{text}", ["🌷"]),
                          ("台词", []), ("台词", ["🌷", "💸"]), ("台词", ["🌷🌷"]), ("台词", ["1"])] {
        let mark: [String: Any] = ["i": 0, "text": text, "emoji": emoji]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["marks": [mark]]), as: UTF8.self)
        let result = try await generateSprite(json)
        #expect(result.quips.isEmpty)
        #expect(result.declined == [0, 1, 2, 3])
    }
}

@Test func spriteGenerationEnforcesBothLanguageLimits() async throws {
    for lang in Lang.allCases {
        let limit = lang == .zh ? 14 : 40
        let character = lang == .zh ? "字" : "x"
        let marks: [[String: Any]] = [
            ["i": 0, "text": String(repeating: character, count: limit), "emoji": ["🌷"]],
            ["i": 1, "text": String(repeating: character, count: limit + 1), "emoji": ["🌷"]]
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["marks": marks]), as: UTF8.self)
        let result = try await generateSprite(json, lang: lang)
        #expect(result.quips.count == 1)
        #expect(result.quips[0]?.text.count == limit)
        #expect(result.declined == [1, 2, 3])
    }
}

@Test func spriteGenerationExposesMalformedJSON() async {
    await #expect(throws: DecodingError.self) { try await generateSprite(#"{"marks":[{"i":0,"text":"台词"}]}"#) }
}

@Test func spritePromptTruncatesCandidatesWithoutReplacingTheirPlaceholders() {
    let text = "{{k}}" + String(repeating: "字", count: 40)
    let prompt = GenerationPrompts.spriteMarks(app: "{{title}}", title: "{{app}}", targets: [("name", text)], persona: .sharp, lang: .zh)
    #expect(prompt.contains("应用：{{title}}"))
    #expect(prompt.contains("窗口：{{app}}"))
    #expect(prompt.contains("0. [name] " + String(text.prefix(40)) + "\n"))
    #expect(!prompt.contains(text))
    #expect(prompt.contains("最多 1 条"))
}

@Test func spritePromptSnapshotZH() {
    let expected = #"""
你是 LifeNarrator，一只住在用户电脑里的吵闹小精灵。用户刚切到下面这个窗口，你用细框圈出屏幕上的几处文字，在旁边各写一句小旁白。

应用：Fixture
窗口：Feed
候选：
0. [money] ¥1,299.00
1. [deadline] 截止周五 18:00 前提交
2. [name] 张三
3. [alert] 构建失败：3 个错误

人设：毒舌：嘴碎、爱吐槽、一针见血，但本质是损友，损完还会留一分可爱。不骂人，不攻击外貌、智商、家庭。

要求：
- 只给值得说一句的候选写旁白，无聊的直接跳过，不要凑数；最多 4 条。
- 每条只针对那一处文字，不复述它，不超过 14 个汉字（标点算字，不写表情）。
- 像朋友凑过来瞄一眼随口一句：可爱、好笑、有点意味深长；不是口号，不说教。
- 不恶毒：不攻击外貌、智商、家庭、身份；不脏话；不涉及政治、宗教、色情、暴力；不编造屏幕上没有的事。
- 每条配 1 个表情，放在 emoji 数组里。
- 只输出 JSON：{"marks":[{"i":序号,"text":"…","emoji":["…"]}]}
"""#
    #expect(GenerationPrompts.spriteMarks(app: "Fixture", title: "Feed", targets: spriteTargets, persona: .sharp, lang: .zh) == expected)
}

@Test func spritePromptSnapshotEN() {
    let expected = #"""
You are LifeNarrator, a noisy little sprite living in the user's computer. The user just switched to the window below. You draw thin boxes around a few bits of on-screen text and whisper one line next to each.

App: Fixture
Window: -
Candidates:
0. [money] ¥1,299.00
1. [deadline] 截止周五 18:00 前提交
2. [name] 张三
3. [alert] 构建失败：3 个错误

Persona: Gentle: soft, comforting, quietly encouraging, like a kind little creature. Can be a bit clingy, never preachy.

Requirements:
- Only write a line for candidates worth a remark; skip boring ones instead of padding. At most 4 lines.
- Each line is about that one bit of text, without repeating it; at most 40 characters, punctuation included, no emoji in the text.
- Like a friend peeking over your shoulder: cute, funny, a little knowing. Not a slogan, never preachy.
- Never mean: nothing about looks, intelligence, family or identity; no profanity; no politics, religion, sex or violence; do not invent facts that are not on screen.
- Give each line exactly one emoji in the emoji array.
- Output JSON only: {"marks":[{"i":index,"text":"…","emoji":["…"]}]}
"""#
    #expect(GenerationPrompts.spriteMarks(app: "Fixture", title: "", targets: spriteTargets, persona: .gentle, lang: .en) == expected)
}
