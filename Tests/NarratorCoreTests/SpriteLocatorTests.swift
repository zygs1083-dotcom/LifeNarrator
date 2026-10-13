import Foundation
import Testing
@testable import NarratorCore

@Test func spriteLocatorFindsEveryQuoteInAllSixDesignExamples() throws {
    for examples in [GenerationPrompts.spriteExamplesZH, GenerationPrompts.spriteExamplesEN] {
        let screens = examples.components(separatedBy: "\n\n")
        #expect(screens.count == 3)
        for example in screens {
            let rows = example.split(separator: "\n").filter { $0.first?.isNumber == true }
            let lines = rows.map { line(String($0.split(separator: "|", maxSplits: 1)[1].dropFirst())) }
            struct Batch: Decodable { var marks: [RawMark] }
            let json = String(example.split(separator: "\n").last!)
            let batch = try JSONDecoder().decode(Batch.self, from: Data(json.utf8))
            for mark in batch.marks {
                let hit = try #require(SpriteLocator.locate(quote: mark.q, lineHint: mark.l, in: lines))
                #expect(hit.lineIndex == mark.l)
                #expect(String(lines[hit.lineIndex].text[hit.range]) == mark.q)
                #expect(mark.t.count <= (examples == GenerationPrompts.spriteExamplesZH ? 14 : 40))
            }
        }
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
