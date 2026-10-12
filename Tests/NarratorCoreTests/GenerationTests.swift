import Foundation
import Testing
@testable import NarratorCore

let validGenerated = [GeneratedQuip(text: "第一句", emoji: ["👨‍👩‍👧‍👦"]), GeneratedQuip(text: "第二句", emoji: ["🇨🇳"]), GeneratedQuip(text: "第三句", emoji: ["🌷"])]
@Test func validationTrimsAndAppliesCharacterLimits() {
    let generated = validGenerated + [GeneratedQuip(text: "  " + String(repeating: "中", count: 14) + " \n", emoji: ["☀️"]), GeneratedQuip(text: String(repeating: "中", count: 15), emoji: ["🌷"])]
    let result = QuipValidator.validate(generated, rule: rule(), lang: .zh, persona: .sharp)
    #expect(result.count == 4)
    #expect(result.last?.text == String(repeating: "中", count: 14))
    let english = validGenerated + [GeneratedQuip(text: String(repeating: "x", count: 40), emoji: ["🌷"]), GeneratedQuip(text: String(repeating: "x", count: 41), emoji: ["🌷"])]
    #expect(QuipValidator.validate(english, rule: rule(), lang: .en, persona: .sharp).count == 4)
}
@Test func validationRejectsUnknownPlaceholders() {
    var target = rule()
    target.variables = ["name": "张三"]
    let generated = validGenerated + [GeneratedQuip(text: "{name}来了", emoji: ["🌷"]), GeneratedQuip(text: "{unknown}来了", emoji: ["🌷"]), GeneratedQuip(text: "{label}来了", emoji: ["🌷"])]
    #expect(QuipValidator.validate(generated, rule: target, lang: .zh, persona: .sharp).map(\.text) == ["第一句", "第二句", "第三句", "{name}来了"])
}
@Test func validationRejectsBadEmojiAndEmojiInText() {
    let bad = [GeneratedQuip(text: "zero", emoji: []), GeneratedQuip(text: "four", emoji: ["🌷", "🌷", "🌷", "🌷"]),
               GeneratedQuip(text: "digit", emoji: ["1"]), GeneratedQuip(text: "digit variation", emoji: ["1️"]), GeneratedQuip(text: "symbol", emoji: ["+"]),
               GeneratedQuip(text: "many", emoji: ["🌷🌷"]), GeneratedQuip(text: "embedded 🌷", emoji: ["🌷"])]
    #expect(QuipValidator.validate(validGenerated + bad, rule: rule(), lang: .zh, persona: .sharp).count == 3)
}
@Test func validationDeduplicatesOnlySameRuleLanguagePersona() {
    let target = rule(quips: [quip("第一句"), quip("other", lang: .en), quip("gentle", persona: .gentle)])
    let generated = validGenerated + [GeneratedQuip(text: " OTHER ", emoji: ["🌷"]), GeneratedQuip(text: "ｏｔｈｅｒ", emoji: ["🌷"]), GeneratedQuip(text: "gentle", emoji: ["🌷"])]
    #expect(QuipValidator.validate(generated, rule: target, lang: .zh, persona: .sharp).map(\.text) == ["第二句", "第三句", "OTHER", "gentle"])
}
@Test func validationFailsBatchWithFewerThanThreeRemaining() {
    #expect(QuipValidator.validate(Array(validGenerated.prefix(2)), rule: rule(), lang: .zh, persona: .sharp).isEmpty)
    #expect(QuipValidator.validate(validGenerated, rule: rule(quips: [quip("第一句")]), lang: .zh, persona: .sharp).isEmpty)
}
@Test func fallbackCompilesChinesePerson() throws {
    let result = try RuleCompiler.compileWithoutModel(input: "张三是我领导", pack: RuleLoader.loadBuiltin(), now: epoch)
    #expect(result.kind == .person)
    #expect(result.label.zh == "张三")
    #expect(result.match.aliases == ["张三"])
    #expect(result.match.region == .header)
    #expect(result.highlight)
    #expect(result.sentiment == .neutral)
    #expect(result.quips.isEmpty)
}
@Test func fallbackCompilesEnglishPersonAndPreservesName() throws {
    let result = try RuleCompiler.compileWithoutModel(input: "Alice is my boss", pack: RuleLoader.loadBuiltin(), now: epoch)
    #expect(result.kind == .person)
    #expect(result.label.en == "Alice")
    #expect(result.match.aliases == ["Alice"])
}
@Test func fallbackCompilesKnownSiteAppAndDomain() throws {
    let resources = try RuleLoader.loadBuiltin()
    let site = try RuleCompiler.compileWithoutModel(input: "我讨厌谷歌", pack: resources, now: epoch)
    #expect(site.kind == .site)
    #expect(site.sentiment == .dislike)
    #expect(site.match.domains!.contains("google.com"))
    let app = try RuleCompiler.compileWithoutModel(input: "我喜欢钉钉", pack: resources, now: epoch)
    #expect(app.kind == .app)
    #expect(app.sentiment == .like)
    #expect(app.match.bundleIds!.contains("com.alibaba.DingTalkMac"))
    let xcode = try RuleCompiler.compileWithoutModel(input: "我喜欢Xcode", pack: resources, now: epoch)
    #expect(xcode.kind == .app)
    #expect(xcode.label.zh == "Xcode")
    let domain = try RuleCompiler.compileWithoutModel(input: "I hate www.example.org", pack: resources, now: epoch)
    #expect(domain.kind == .site)
    #expect(domain.match.domains == ["example.org"])
}
@Test func fallbackCompilesTopicAndRejectsShortKeywords() throws {
    let resources = try RuleLoader.loadBuiltin()
    let topic = try RuleCompiler.compileWithoutModel(input: "讨厌开会", pack: resources, now: epoch)
    #expect(topic.kind == .topic)
    #expect(topic.label.zh == "开会")
    #expect(topic.match.aliases == ["开会"])
    #expect(topic.sentiment == .dislike)
    #expect(throws: GenerationError.self) { try RuleCompiler.compileWithoutModel(input: "我讨厌", pack: resources, now: epoch) }
    #expect(throws: GenerationError.self) { try RuleCompiler.compileWithoutModel(input: "Al is my boss", pack: resources, now: epoch) }
}
