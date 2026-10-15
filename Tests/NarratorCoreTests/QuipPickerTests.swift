import Foundation
import Testing
@testable import NarratorCore

struct SeededRandom: RandomNumberGenerator {
    var seed: UInt64
    var calls = 0
    mutating func next() -> UInt64 {
        calls += 1
        seed &+= 0x9e3779b97f4a7c15
        var z = seed
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
func quip(_ text: String, lang: Lang = .zh, persona: Persona = .sharp, when: When = .any) -> Quip {
    Quip(lang: lang, persona: persona, text: text, emoji: ["🌷"], when: when)
}
func pack(rules: [Rule] = [], generic: [Quip] = []) -> QuipPack {
    QuipPack(version: 1, rules: rules, generic: ["dislike": generic])
}
@Test func pickerNoRepeatsForTwoHoursAndNewCycle() {
    var picker = QuipPicker()
    var random = SeededRandom(seed: 1)
    let target = rule(quips: [quip("第一句"), quip("第二句"), quip("第三句")])
    var texts: [String] = []
    for index in 0..<3 {
        texts.append(picker.pick(for: target, lang: .zh, persona: .sharp, pack: pack(), now: epoch.addingTimeInterval(Double(index)), using: &random)!.text)
    }
    #expect(Set(texts).count == 3)
    #expect(picker.pick(for: target, lang: .zh, persona: .sharp, pack: pack(), now: epoch.addingTimeInterval(7199), using: &random) == nil)
    #expect(picker.pick(for: target, lang: .zh, persona: .sharp, pack: pack(), now: epoch.addingTimeInterval(7202), using: &random) != nil)
}
@Test func pickerFinishesCycleEvenAfterTwoHours() {
    var picker = QuipPicker()
    var random = SeededRandom(seed: 2)
    let target = rule(quips: [quip("one"), quip("two"), quip("three")])
    let a = picker.pick(for: target, lang: .zh, persona: .sharp, pack: pack(), now: epoch, using: &random)!.text
    let b = picker.pick(for: target, lang: .zh, persona: .sharp, pack: pack(), now: epoch.addingTimeInterval(8000), using: &random)!.text
    let c = picker.pick(for: target, lang: .zh, persona: .sharp, pack: pack(), now: epoch.addingTimeInterval(16000), using: &random)!.text
    #expect(Set([a, b, c]).count == 3)
    let calls = random.calls
    #expect(picker.pick(for: target, lang: .zh, persona: .sharp, pack: pack(), now: epoch.addingTimeInterval(24000), using: &random) != nil)
    #expect(random.calls > calls)
}
@Test func pickerFiltersLanguagePersonaAndSeparatesRules() {
    var picker = QuipPicker()
    var random = SeededRandom(seed: 3)
    let target = rule(quips: [quip("中文"), quip("gentle", persona: .gentle), quip("English", lang: .en)])
    #expect(picker.pick(for: target, lang: .zh, persona: .sharp, pack: pack(), now: epoch, using: &random)?.text == "中文")
    #expect(picker.pick(for: target, lang: .zh, persona: .gentle, pack: pack(), now: epoch, using: &random)?.text == "gentle")
    #expect(picker.pick(for: target, lang: .en, persona: .sharp, pack: pack(), now: epoch, using: &random)?.text == "English")
    var another = target
    another.id = "another"
    #expect(picker.pick(for: another, lang: .zh, persona: .sharp, pack: pack(), now: epoch, using: &random)?.text == "中文")
}
@Test func pickerTimeVariantsHaveSeventyPercentProbability() {
    let target = rule(quips: [quip("normal"), quip("own timed", when: .lateNight)])
    let time = rule("builtin.time.lateNight", kind: .time, match: Match(when: .lateNight), quips: [quip("builtin timed", when: .lateNight)])
    let resources = pack(rules: [time])
    var random = SeededRandom(seed: 7)
    var timed = 0
    var selected = Set<String>()
    for _ in 0..<1000 {
        var picker = QuipPicker()
        let text = picker.pick(for: target, lang: .zh, persona: .sharp, pack: resources, now: date("2026-10-12T23:30:00Z"), calendar: utcCalendar, using: &random)!.text
        if text != "normal" { timed += 1 }
        selected.insert(text)
    }
    #expect((650...750).contains(timed))
    #expect(selected == ["normal", "own timed", "builtin timed"])
}
@Test func pickerDisabledTimeRulesAndDaytime() {
    let target = rule(quips: [quip("normal")])
    let time = rule("builtin.time.lateNight", kind: .time, match: Match(when: .lateNight), quips: [quip("timed", when: .lateNight)])
    var random = SeededRandom(seed: 11)
    var picker = QuipPicker()
    #expect(picker.pick(for: target, lang: .zh, persona: .sharp, pack: pack(rules: [time]), disabledBuiltinIds: [time.id], now: date("2026-10-12T23:30:00Z"), calendar: utcCalendar, using: &random)?.text == "normal")
    var daytime = QuipPicker()
    #expect(daytime.pick(for: target, lang: .zh, persona: .sharp, pack: pack(rules: [time]), now: date("2026-10-12T15:00:00Z"), calendar: utcCalendar, using: &random)?.text == "normal")
}
@Test func pickerRendersVariablesSkipsUnknownAndFallsBack() {
    var target = rule(quips: [quip("{unknown}")])
    target.variables = ["name": "张三", "nick": "猪领导"]
    #expect(QuipPicker.render("{name} {nick} {label}", rule: target, lang: .zh) == "张三 猪领导 会议")
    var picker = QuipPicker()
    var random = SeededRandom(seed: 1)
    #expect(picker.pick(for: target, lang: .zh, persona: .sharp, pack: pack(generic: [quip("{label}来了")]), now: epoch, using: &random)?.text == "会议来了")
    #expect(picker.pick(for: target, lang: .zh, persona: .sharp, pack: pack(generic: [quip("{label}来了")]), now: epoch.addingTimeInterval(1), using: &random) == nil)
}

@Test func pickerForgetClearsQueuesAndTwoHourHistoryForOnlyThatRule() {
    var picker = QuipPicker()
    var random = SeededRandom(seed: 23)
    let target = rule("target", quips: [quip("one"), quip("two"), quip("three")])
    let other = rule("other", quips: [quip("alone")])
    _ = picker.pick(for: target, lang: .zh, persona: .sharp, pack: pack(), now: epoch, using: &random)
    _ = picker.pick(for: other, lang: .zh, persona: .sharp, pack: pack(), now: epoch, using: &random)
    picker.forget(ruleID: target.id)
    let calls = random.calls
    #expect(picker.pick(for: target, lang: .zh, persona: .sharp, pack: pack(), now: epoch, using: &random) != nil)
    #expect(random.calls > calls)
    for _ in 0..<2 { #expect(picker.pick(for: target, lang: .zh, persona: .sharp, pack: pack(), now: epoch, using: &random) != nil) }
    #expect(picker.pick(for: target, lang: .zh, persona: .sharp, pack: pack(), now: epoch, using: &random) == nil)
    #expect(picker.pick(for: other, lang: .zh, persona: .sharp, pack: pack(), now: epoch, using: &random) == nil)
    picker.forget(ruleID: target.id)
    #expect(picker.pick(for: target, lang: .zh, persona: .sharp, pack: pack(), now: epoch, using: &random) != nil)
}

@Test func pickerChecksRenderedTextAcrossRulesAndReturnsNilWhenExhausted() {
    var said = SaidHistory()
    said.record("会议来了", now: epoch)
    var picker = QuipPicker()
    var random = SeededRandom(seed: 5)
    let first = rule("first", quips: [quip("{label}来了"), quip("咖啡还没凉")])
    let check: (String) -> Bool = { said.isRepeat($0, now: epoch) }
    #expect(picker.pick(for: first, lang: .zh, persona: .sharp, pack: pack(), now: epoch,
        isRepeat: check, using: &random)?.text == "咖啡还没凉")
    let second = rule("second", quips: [quip("{label}来了")])
    #expect(picker.pick(for: second, lang: .zh, persona: .sharp,
        pack: pack(generic: [quip("会议来了！")]), now: epoch, isRepeat: check, using: &random) == nil)
}
