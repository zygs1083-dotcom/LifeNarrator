import Foundation
import NarratorCore
@testable import NarratorMac
import XCTest

final class LlamaGrammarTests: XCTestCase {
    private let rule = Rule(id: "r", kind: .topic, source: .user, label: Label(zh: "开会", en: "Meetings"),
                            sentiment: .dislike, match: Match(aliases: ["开会"], region: .anywhere), highlight: false)

    /// The `{m,n}` bound of the first rule line starting with `name ::=`.
    private func bound(_ grammar: String, rule name: String) -> Int {
        let line = grammar.split(separator: "\n").first { $0.hasPrefix("\(name) ::=") }!
        let match = line.range(of: "\\{\\d+,(\\d+)\\}", options: .regularExpression)!
        return Int(line[match].split(separator: ",")[1].dropLast())!
    }

    func testSchemasSelectTheirGrammar() throws {
        XCTAssertEqual(try LlamaGrammar.grammar(for: GenerationPrompts.quipsSchema), LlamaGrammar.quips)
        XCTAssertEqual(try LlamaGrammar.grammar(for: GenerationPrompts.spriteMarksSchema), LlamaGrammar.spriteMarks)
        XCTAssertEqual(try LlamaGrammar.grammar(for: GenerationPrompts.compiledRuleSchema), LlamaGrammar.compiledRule)
        XCTAssertThrowsError(try LlamaGrammar.grammar(for: "{}"))
    }

    func testQuipGrammarLimitsMatchValidator() {
        let grammar = LlamaGrammar.quips
        XCTAssertTrue(grammar.contains(#"zh ::= [一-鿿"#))
        XCTAssertTrue(grammar.contains("en ::= [A-Za-z0-9 "))
        XCTAssertTrue(grammar.contains("emoji (ws \",\" ws emoji){0,2}"))
        let zhLimit = bound(grammar, rule: "zh")
        let enLimit = bound(grammar, rule: "en")
        let valid = [(String(repeating: "会", count: 14), Lang.zh), (String(repeating: "x", count: 40), Lang.en)]
        let invalid = [(String(repeating: "会", count: 15), Lang.zh), (String(repeating: "x", count: 41), Lang.en)]
        for (text, lang) in valid {
            XCTAssertLessThanOrEqual(text.count, lang == .zh ? zhLimit : enLimit, text)
            let valid = QuipValidator.validate([GeneratedQuip(text: text, emoji: ["🌷"]), GeneratedQuip(text: "b", emoji: ["🌷"]), GeneratedQuip(text: "c", emoji: ["🌷"])], rule: rule, lang: lang, persona: .sharp)
            XCTAssertEqual(valid.first?.text, text)
        }
        for (text, lang) in invalid {
            XCTAssertGreaterThan(text.count, lang == .zh ? zhLimit : enLimit, text)
            let valid = QuipValidator.validate([GeneratedQuip(text: text, emoji: ["🌷"]), GeneratedQuip(text: "b", emoji: ["🌷"]), GeneratedQuip(text: "c", emoji: ["🌷"]), GeneratedQuip(text: "d", emoji: ["🌷"])], rule: rule, lang: lang, persona: .sharp)
            XCTAssertFalse(valid.map(\.text).contains(text))
        }
        // Three emoji strings are the most the grammar emits and the most the validator accepts.
        let three = QuipValidator.validate([GeneratedQuip(text: "a", emoji: ["🌷", "🐷", "✨"]), GeneratedQuip(text: "b", emoji: ["🌷"]), GeneratedQuip(text: "c", emoji: ["🌷"])], rule: rule, lang: .en, persona: .sharp)
        XCTAssertEqual(three.first?.emoji.count, 3)
        XCTAssertEqual(bound(grammar, rule: "root") + 1, 12)
    }

    func testSpriteGrammarQuoteAndMarkLimits() {
        let grammar = LlamaGrammar.spriteMarks
        for name in ["text", "emoji", "ebase", "ws"] {
            let sprite = grammar.split(separator: "\n").first { $0.hasPrefix("\(name) ::=") }
            let quips = LlamaGrammar.quips.split(separator: "\n").first { $0.hasPrefix("\(name) ::=") }
            XCTAssertEqual(sprite, quips)
        }
        XCTAssertEqual(bound(grammar, rule: "root") + 1, 8)
        XCTAssertEqual(bound(grammar, rule: "quote"), 32)
        XCTAssertEqual(bound(grammar, rule: "zh"), 20)
        XCTAssertEqual(bound(grammar, rule: "en"), 56)
        XCTAssertTrue(grammar.contains("line ::= [0-9] | [1-9] [0-9]"))
        XCTAssertTrue(grammar.contains("qchar{2,32}"))
        XCTAssertTrue(grammar.contains("「」%.A-Za-z0-9 "))
        XCTAssertTrue(grammar.contains("…()%-]"))
    }

    func testCompiledRuleGrammarCoversSchemaEnumsAndArrayLimits() {
        let grammar = LlamaGrammar.compiledRule
        for kind in ["app", "site", "person", "topic"] { XCTAssertTrue(grammar.contains("\"\\\"\(kind)\\\"\"")) }
        for sentiment in ["dislike", "like", "neutral"] { XCTAssertTrue(grammar.contains("\"\\\"\(sentiment)\\\"\"")) }
        XCTAssertEqual(bound(grammar, rule: "aliases") + 1, 8)
        XCTAssertEqual(bound(grammar, rule: "domains") + 1, 6)
        XCTAssertEqual(bound(grammar, rule: "appNames") + 1, 4)
        XCTAssertTrue(grammar.contains("\"\\\"highlight\\\"\" ws \":\" ws (\"true\" | \"false\")"))
    }
}
