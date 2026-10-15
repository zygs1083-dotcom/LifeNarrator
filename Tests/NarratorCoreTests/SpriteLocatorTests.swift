import Foundation
import Testing
@testable import NarratorCore

@Test func spriteExamplePoolHasLocalizedScenesAndValidPersonaVoices() throws {
    #expect(SpriteExample.pool.count >= 10)
    #expect(Set(SpriteExample.pool.map(\.id)).count == SpriteExample.pool.count)
    #expect(Set(SpriteExample.pool.map(\.id)).isSuperset(of: ["backup", "headphones", "chat", "terminal", "ai-dialogue", "news", "technical-docs", "settings", "video", "spreadsheet", "email"]))
    for scene in SpriteExample.pool {
        for lang in Lang.allCases {
            let screen = lang == .zh ? scene.zh : scene.en
            #expect((2...3).contains(screen.marks.count))
            let lines = screen.lines.map { line($0) }
            for mark in screen.marks {
                #expect(screen.lines.indices.contains(mark.l))
                #expect(screen.lines[mark.l].contains(mark.q))
                #expect((2...32).contains(mark.q.count))
                let hit = try #require(SpriteLocator.locate(quote: mark.q, lineHint: mark.l, in: lines))
                #expect(hit.lineIndex == mark.l)
                #expect(String(lines[hit.lineIndex].text[hit.range]) == mark.q)
                for profile in PersonaCatalog.builtin.profiles {
                    let voice = try #require(mark.voices[profile.id.rawValue])
                    if lang == .zh { #expect(voice.t.count <= profile.limit.zh) }
                    else { #expect(voice.t.split(whereSeparator: \.isWhitespace).count < profile.limit.en) }
                    #expect(!voice.t.contains(mark.q))
                    #expect(!voice.t.contains(where: QuipValidator.isEmoji))
                    #expect(voice.e.count == 1 && QuipValidator.isEmoji(voice.e.first!))
                }
            }
            for persona in PersonaCatalog.builtin.profiles.map(\.id) {
                let openings = screen.marks.map { String($0.voices[persona.rawValue]!.t.prefix(2)) }
                #expect(Set(openings).count == openings.count)
            }
        }
    }
}

@Test func spriteExamplePoolLimitsRepeatedPhrasesAndOpeningsAcrossScenes() throws {
    let englishWords = try NSRegularExpression(pattern: "[a-z]+(?:['’][a-z]+)*")
    for lang in Lang.allCases {
        for persona in PersonaCatalog.builtin.profiles.map(\.id) {
            var phrases: [String: Int] = [:]
            var openings: [String: Int] = [:]
            for scene in SpriteExample.pool {
                let screen = lang == .zh ? scene.zh : scene.en
                for mark in screen.marks {
                    let text = mark.voices[persona.rawValue]!.t.lowercased()
                    let fragments: Set<String>
                    let opening: String
                    if lang == .zh {
                        let han = Array(text.replacingOccurrences(of: "[^\\p{Han}]", with: "", options: .regularExpression))
                        fragments = Set(han.indices.dropLast().map { String(han[$0...($0 + 1)]) })
                        opening = String(han.prefix(2))
                    } else {
                        let words = englishWords.matches(in: text, range: NSRange(text.startIndex..., in: text))
                            .map { String(text[Range($0.range, in: text)!]) }
                        // Cat examples deliberately use "meow" in about half their lines.
                        fragments = Set(words.filter { $0.count > 3 && !(persona == .cat && $0 == "meow") })
                        opening = words.first!
                    }
                    for fragment in fragments { phrases[fragment, default: 0] += 1 }
                    openings[opening, default: 0] += 1
                }
            }
            for (phrase, count) in phrases {
                #expect(count <= 2, "\(lang.rawValue)/\(persona.rawValue): \(phrase) appears in \(count) lines")
            }
            for (opening, count) in openings {
                #expect(count <= 2, "\(lang.rawValue)/\(persona.rawValue): \(opening) starts \(count) lines")
            }
        }
    }
}

@Test func catExamplesUseMeowInAboutHalfOfEachLanguage() {
    for lang in Lang.allCases {
        let texts = SpriteExample.pool.flatMap { scene in
            (lang == .zh ? scene.zh : scene.en).marks.map { $0.voices["cat"]!.t }
        }
        let count = texts.filter { $0.contains(lang == .zh ? "喵" : "meow") }.count
        #expect((0.4...0.6).contains(Double(count) / Double(texts.count)))
    }
}

@Test func spriteLocatorFoldsAndPrefersHintThenShortestLine() throws {
    let lines = [line("long ＨＥＬＬＯ   World suffix"), line("hello world"), line("Other text")]
    let hint = try #require(SpriteLocator.locate(quote: "hello world", lineHint: 0, in: lines))
    #expect(hint.lineIndex == 0)
    #expect(String(lines[0].text[hint.range]) == "ＨＥＬＬＯ   World")
    #expect(SpriteLocator.locate(quote: "HELLO   world", lineHint: 2, in: lines)?.lineIndex == 1)
    #expect(SpriteLocator.locate(quote: "hello world", lineHint: 99, in: lines)?.lineIndex == 1)
    #expect(SpriteLocator.locate(quote: "missing", lineHint: 0, in: lines) == nil)
    let quote = try JSONDecoder().decode(String.self, from: Data(#""say \"hi\"""#.utf8))
    let quoted = line("Please say \"hi\" now")
    let hit = try #require(SpriteLocator.locate(quote: quote, lineHint: 0, in: [quoted]))
    #expect(String(quoted.text[hit.range]) == quote)
}

@Test func spritePositionsRejectSameRowsAndVerticalDistancesBelowTwentyFour() {
    let first = SpriteLocator.Position(lineIndex: 0, rect: CGRect(x: 0, y: 100, width: 50, height: 16))
    #expect(SpriteLocator.conflicts(.init(lineIndex: 0, rect: CGRect(x: 500, y: 200, width: 50, height: 16)), with: [first]))
    #expect(SpriteLocator.conflicts(.init(lineIndex: 1, rect: CGRect(x: 500, y: 123.999, width: 50, height: 16)), with: [first]))
    #expect(!SpriteLocator.conflicts(.init(lineIndex: 1, rect: CGRect(x: 0, y: 124, width: 50, height: 16)), with: [first]))
    #expect(SpriteLocator.conflicts(.init(lineIndex: -1, rect: CGRect(x: 0, y: 110, width: 50, height: 16)), with: [first]))
    #expect(!SpriteLocator.conflicts(first, with: []))
}

@Test func spritePositionsWithoutRectsOnlyConflictOnKnownRows() {
    let withRect = SpriteLocator.Position(lineIndex: 0, rect: CGRect(x: 0, y: 100, width: 50, height: 16))
    let withoutRect = SpriteLocator.Position(lineIndex: 0, rect: nil)
    #expect(SpriteLocator.conflicts(withoutRect, with: [withRect]))
    #expect(SpriteLocator.conflicts(withRect, with: [withoutRect]))
    #expect(SpriteLocator.conflicts(withoutRect, with: [withoutRect]))
    let otherRow = SpriteLocator.Position(lineIndex: 1, rect: nil)
    #expect(!SpriteLocator.conflicts(otherRow, with: [withRect]))
    #expect(!SpriteLocator.conflicts(withRect, with: [otherRow]))
    #expect(!SpriteLocator.conflicts(otherRow, with: [withoutRect]))
    #expect(!SpriteLocator.conflicts(.init(lineIndex: -1, rect: nil), with: [.init(lineIndex: -1, rect: nil)]))
}
