import Foundation
import Testing
@testable import NarratorCore

private let newPackPersonas: [Persona] = [.teacher, .mom, .hype, .cat]

@Test func builtinQuipPoolsCoverAllPersonasAndRender() throws {
    let pack = try RuleLoader.loadBuiltin()
    let genericPools = pack.generic.map { sentiment, quips in
        var target = rule("generic.\(sentiment)")
        target.sentiment = Sentiment(rawValue: sentiment)!
        #expect(quips.allSatisfy { $0.text.contains("{label}") })
        return (target, quips)
    }
    for (target, quips) in pack.rules.map({ ($0, $0.quips) }) + genericPools {
        #expect(Set(quips.map(\.persona)) == Set(PersonaCatalog.builtin.profiles.map(\.id)))
        for persona in PersonaCatalog.builtin.profiles.map(\.id) {
            for lang in Lang.allCases {
                let pool = quips.filter { $0.persona == persona && $0.lang == lang }
                if newPackPersonas.contains(persona) {
                    #expect(pool.count == (target.id.hasPrefix("generic.") ? 8 : 6))
                    #expect(pool.allSatisfy { $0.when == (target.match.when ?? .any) })
                } else {
                    #expect(pool.count >= 8)
                }
                #expect(Set(pool.map(\.text)).count == pool.count)
                for quip in pool {
                    let rendered = try #require(QuipPicker.render(quip.text, rule: target, lang: lang))
                    #expect(!rendered.contains("{") && !rendered.contains("}"))
                    #expect(!quip.text.isEmpty)
                    #expect(quip.text.count <= (persona == .teacher ? (lang == .zh ? 22 : 60) : (lang == .zh ? 14 : 40)))
                    #expect(!"，,、；;：:".contains(quip.text.last!))
                    #expect(!quip.text.contains(where: QuipValidator.isEmoji))
                    #expect((1...3).contains(quip.emoji.count))
                    #expect(quip.emoji.allSatisfy { $0.count == 1 && QuipValidator.isEmoji($0.first!) })
                }
            }
        }
    }
}

@Test func newOfflinePacksLimitRepeatedWordsAndPoolOpenings() throws {
    let pack = try RuleLoader.loadBuiltin()
    let sprite = try SpriteQuips.loadBuiltin()
    let pools = pack.rules.map(\.quips) + Array(pack.generic.values) + Array(sprite.categories.values)
    let englishWords = try NSRegularExpression(pattern: "[a-z]+(?:['’][a-z]+)*")
    let englishFunctionWords = Set("""
        a an the i me my mine myself we us our ours ourselves you your yours yourself yourselves he him his
        himself she her hers herself it its itself they them their theirs themselves this that these those am is
        are was were be been being do does did doing have has had having can could may might must shall should
        will would to of in on at by for from with without as into onto over under between through about around
        before after during until since and or but so if than then because while although though not no nor yes
        too very just only even also still already yet what which who whom whose when where why how all any each
        every some such both few many much most more other another same own up down out off again here there now
        it's that's there's here's let's i'm i've i'll i'd you're you've you'll you'd he's she's we're we've
        we'll they're they've they'll isn't aren't wasn't weren't don't doesn't didn't hasn't haven't hadn't
        can't couldn't won't wouldn't shouldn't mustn't
        """.split(whereSeparator: \.isWhitespace).map(String.init))
    let chineseFunctionCharacters = Set("你我他她它们的了吗吧呢一下这那是也在有和与把被啊呀哦么个些都就着得地到对给不还为从以而之其所及或并")
    let openingTokens = try NSRegularExpression(pattern: "\\{[^}]+\\}|[a-z]+(?:['’][a-z]+)*")
    for persona in newPackPersonas {
        let all = pools.flatMap { $0 }.filter { $0.persona == persona }
        var phrases: [String: Int] = [:]
        for pool in pools {
            for lang in Lang.allCases {
                let texts = pool.filter { $0.persona == persona && $0.lang == lang }.map(\.text)
                var openings: [String] = []
                for text in texts {
                    let plain = text.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "\\{[^}]+\\}", with: "", options: .regularExpression)
                    let fragments: Set<String>
                    if lang == .zh {
                        let han = Array(plain.replacingOccurrences(of: "[^\\p{Han}]", with: "", options: .regularExpression))
                        fragments = Set(han.indices.dropLast().map { String(han[$0...($0 + 1)]) }
                            .filter { !$0.allSatisfy(chineseFunctionCharacters.contains) })
                        openings.append(String(text.prefix(2)))
                    } else {
                        fragments = Set(englishWords.matches(in: plain, range: NSRange(plain.startIndex..., in: plain))
                            .map { String(plain[Range($0.range, in: plain)!]) }.filter { !englishFunctionWords.contains($0) })
                        let lower = text.lowercased()
                        let first = try #require(openingTokens.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)))
                        openings.append(String(lower[Range(first.range, in: lower)!]))
                    }
                    for fragment in fragments { phrases[fragment, default: 0] += 1 }
                }
                #expect(Set(openings).count == openings.count, "\(persona.rawValue)/\(lang.rawValue): \(texts)")
            }
        }
        // Count lines containing a fragment; placeholders are data, not spoken catchphrases.
        for (phrase, count) in phrases {
            #expect(count * 100 <= all.count * 5, "\(persona.rawValue): \(phrase) appears in \(count)/\(all.count) lines")
        }
    }
}

@Test func newOfflinePacksAreSelectedWithoutBorrowingLegacyVoices() throws {
    let pack = try RuleLoader.loadBuiltin()
    let sprite = try SpriteQuips.loadBuiltin()
    let empty = QuipPack(version: 1, rules: [], generic: [:])
    let times: [When: Date] = [.any: date("2026-10-14T12:00:00Z"), .lateNight: date("2026-10-14T23:30:00Z"),
        .mondayMorning: date("2026-10-12T08:00:00Z"), .fridayEvening: date("2026-10-16T17:00:00Z")]
    for persona in newPackPersonas {
        for lang in Lang.allCases {
            let spriteRules = sprite.categories.keys.map {
                sprite.rule(for: $0, text: "Sample", app: "Fixture", title: "Feed", lang: lang)
            }
            for target in pack.rules + spriteRules {
                let pool = target.quips.filter { $0.persona == persona && $0.lang == lang }
                var picker = QuipPicker()
                var random = SeededRandom(seed: 17)
                var seen: Set<String> = []
                // Timed pools are chosen probabilistically, so allow unselected ticks.
                for _ in 0..<(target.kind == .time ? 60 : pool.count) {
                    let result = picker.pick(for: target, lang: lang, persona: persona, pack: empty,
                        now: times[target.match.when ?? .any]!, calendar: utcCalendar, using: &random)
                    if target.kind == .time && result == nil { continue }
                    let chosen = try #require(result)
                    #expect(chosen.persona == persona)
                    #expect(pool.contains { QuipPicker.render($0.text, rule: target, lang: lang) == chosen.text })
                    #expect(seen.insert(chosen.text).inserted)
                }
                #expect(seen.count == pool.count)
                #expect(picker.pick(for: target, lang: lang, persona: persona, pack: empty,
                    now: times[target.match.when ?? .any]!, calendar: utcCalendar, using: &random) == nil)
            }
            for (sentiment, quips) in pack.generic {
                var target = rule()
                target.sentiment = Sentiment(rawValue: sentiment)!
                var picker = QuipPicker()
                var random = SeededRandom(seed: 17)
                let pool = quips.filter { $0.persona == persona && $0.lang == lang }
                var seen: Set<String> = []
                for _ in pool {
                    let chosen = try #require(picker.pick(for: target, lang: lang, persona: persona, pack: pack,
                        now: times[.any]!, calendar: utcCalendar, using: &random))
                    #expect(chosen.persona == persona)
                    #expect(pool.contains { QuipPicker.render($0.text, rule: target, lang: lang) == chosen.text })
                    #expect(seen.insert(chosen.text).inserted)
                }
            }
        }
    }
}
