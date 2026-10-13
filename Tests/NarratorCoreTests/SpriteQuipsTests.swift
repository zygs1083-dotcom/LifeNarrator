import Foundation
import Testing
@testable import NarratorCore

@Test func spritePackContainsAllCombinationsAndValidQuips() throws {
    let pack = try SpriteQuips.loadBuiltin()
    #expect(pack.version == 1)
    #expect(Set(pack.categories.keys) == ["money", "deadline", "name", "action", "revisit"])
    for (_, quips) in pack.categories {
        for lang in Lang.allCases {
            for persona in Persona.allCases {
                let pool = quips.filter { $0.lang == lang && $0.persona == persona }
                #expect(pool.count >= 2)
                #expect(pool.filter { $0.text.contains("{text}") }.count * 3 <= pool.count)
                #expect(Set(pool.map(\.text)).count == pool.count)
                for quip in pool {
                    #expect(!quip.text.isEmpty)
                    #expect(quip.text.count <= (lang == .zh ? 14 : 40))
                    #expect(!"，,、；;：:".contains(quip.text.last!))
                    #expect(!quip.text.contains(where: QuipValidator.isEmoji))
                    #expect((1...3).contains(quip.emoji.count))
                    #expect(quip.emoji.allSatisfy { $0.count == 1 && QuipValidator.isEmoji($0.first!) })
                }
            }
        }
    }
}

@Test func spriteTruncationAndNumericCategoryExceptions() throws {
    #expect(SpriteQuips.truncate(text: "一二三四五六七", lang: .zh) == "一二三四五六…")
    #expect(SpriteQuips.truncate(text: "abcdefghijklm", lang: .en) == "abcdefghijkl…")
    #expect(SpriteQuips.truncate(text: "一二三四五六", lang: .zh) == "一二三四五六")
    #expect(SpriteQuips.truncate(text: "abcdefghijkl", lang: .en) == "abcdefghijkl")
    let pack = try SpriteQuips.loadBuiltin()
    for (category, text) in [("money", "¥1,299.00"), ("deadline", "周五 18:00")] {
        #expect(pack.rule(for: category, text: text, app: "Fixture", title: "Feed", lang: .zh).variables?["text"] == text)
    }
    #expect(pack.rule(for: "deadline", text: "截止周五18:00提交", app: "Fixture", title: "Feed", lang: .zh).variables?["text"] == "截止周五18…")
}

@Test func spriteRulesRenderAndRotatePerTargetWithEmptyPackAtNight() throws {
    var pack = try SpriteQuips.loadBuiltin()
    pack.categories["name"] = [quip("{text}在{app}"), quip("回到{title}")]
    let target = pack.rule(for: "name", text: "一二三四五六七", app: "应用", title: "窗口", lang: .zh)
    let same = pack.rule(for: "name", text: " 一二三四五六七 ", app: "其他", title: "其他", lang: .zh)
    let other = pack.rule(for: "name", text: "张三", app: "应用", title: "窗口", lang: .zh)
    #expect(target.id == same.id)
    #expect(target.id != other.id)
    #expect(target.id == "sprite.name.\(stableHash(normalized("一二三四五六七")))")
    #expect(target.kind == .topic && target.source == .builtin && target.sentiment == .neutral && target.highlight)
    #expect(target.match.aliases == ["name"])
    try RuleLoader.validate(target)
    let empty = QuipPack(version: 1, rules: [], generic: [:])
    let night = date("2026-10-12T23:30:00Z")
    var picker = QuipPicker()
    var random = SeededRandom(seed: 42)
    let first = picker.pick(for: target, lang: .zh, persona: .sharp, pack: empty, now: night, calendar: utcCalendar, using: &random)!
    let second = picker.pick(for: target, lang: .zh, persona: .sharp, pack: empty, now: night.addingTimeInterval(1), calendar: utcCalendar, using: &random)!
    #expect(Set([first.text, second.text]) == ["一二三四五六…在应用", "回到窗口"])
    #expect(picker.pick(for: target, lang: .zh, persona: .sharp, pack: empty, now: night.addingTimeInterval(2), calendar: utcCalendar, using: &random) == nil)
    #expect(picker.pick(for: other, lang: .zh, persona: .sharp, pack: empty, now: night, calendar: utcCalendar, using: &random) != nil)
}
