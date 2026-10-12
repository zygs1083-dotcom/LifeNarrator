import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import NarratorCore

let epoch = Date(timeIntervalSince1970: 1_800_000_000)
let content = CGRect(x: 100, y: 100, width: 800, height: 600)
func rule(_ id: String = "rule", kind: RuleKind = .topic, match: Match = Match(aliases: ["会议"]),
          createdAt: Date? = nil, quips: [Quip] = [], highlight: Bool = false) -> Rule {
    Rule(id: id, kind: kind, source: .user, label: Label(zh: "会议", en: "Meeting"), sentiment: .dislike,
         match: match, highlight: highlight, variables: [:], quips: quips, createdAt: createdAt)
}
func snapshot(title: String? = nil, lines: [TextLine] = [], host: String? = nil) -> ContextSnapshot {
    ContextSnapshot(bundleId: "COM.EXAMPLE.APP", appName: "Ｇoogle", pid: 42, windowTitle: title,
                    windowFrame: content, contentFrame: content, host: host, textLines: lines,
                    textSource: .ocr, capturedAt: epoch)
}
func line(_ text: String, x: CGFloat = 400, y: CGFloat = 120, height: CGFloat = 20) -> TextLine {
    TextLine(text: text, rect: CGRect(x: x, y: y, width: 300, height: height))
}
func matches(_ rules: [Rule], _ snapshot: ContextSnapshot, appChanged: Bool = true, hostChanged: Bool = true,
             now: Date = epoch) -> [Candidate] {
    RuleMatcher(rules: rules).candidates(in: snapshot, now: now, appChanged: appChanged, hostChanged: hostChanged, calendar: utcCalendar)
}
var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}
func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

@Test func normalization() {
    #expect(normalized("  Ｇoogle\n ZOË\t  ") == "google zoe")
    #expect(normalized("繁體") == "繁體")
}
@Test func appMatchesBundleAndFallbackNameOnlyOnSwitch() {
    let app = rule(kind: .app, match: Match(bundleIds: ["com.example.app"]))
    let fallback = rule("fallback", kind: .app, match: Match(bundleIds: ["other"], appNames: ["google"]))
    #expect(matches([app, fallback], snapshot()).count == 2)
    #expect(matches([app, fallback], snapshot(), appChanged: false).isEmpty)
}
@Test func domainSuffixRequiresDotAndHostChange() {
    let site = rule(kind: .site, match: Match(domains: ["google.com"]))
    #expect(matches([site], snapshot(host: "google.com")).count == 1)
    #expect(matches([site], snapshot(host: "maps.google.com")).count == 1)
    #expect(matches([site], snapshot(host: "evilgoogle.com")).isEmpty)
    #expect(matches([site], snapshot()).isEmpty)
    #expect(matches([site], snapshot(host: "google.com"), hostChanged: false).isEmpty)
}
@Test func latinBoundariesAndShortAliases() throws {
    let topic = rule(match: Match(aliases: ["三", "Al", "meeting", "张三"]))
    #expect(matches([topic], snapshot(lines: [line("Alice 三 meetings")])).isEmpty)
    #expect(matches([topic], snapshot(lines: [line("meeting!")])).first?.matchedText == "meeting")
    #expect(matches([topic], snapshot(lines: [line("群里提到张三了")])).first?.matchedText == "张三")
    #expect(matches([topic], snapshot(lines: [line("xmeeting 会议meeting")])).isEmpty)
    let json = #"""
    {"kind":"person","label":{"zh":"张三","en":"Zhang San"},"sentiment":"neutral","note":"boss",
     "aliases":["三","Al","张三","Zhang San"],"domains":[],"appNames":[],"highlight":true,"variables":{}}
    """#
    let compiled = try JSONDecoder().decode(CompiledRule.self, from: Data(json.utf8))
    let assembled = try RuleCompiler.assemble(compiled, input: "张三是我领导", now: epoch, resolveBundleIds: { _ in [] })
    #expect(assembled.match.aliases == ["张三", "Zhang San"])
}
@Test func normalizedMatchRetainsOriginalSubstringAndRange() {
    let topic = rule(match: Match(aliases: ["Zoe Zhang"]))
    let text = "hello Ｚoë\t  ZHANG!"
    let candidate = matches([topic], snapshot(lines: [line(text)])).first!
    #expect(candidate.matchedText == "Ｚoë\t  ZHANG")
    #expect(String(text[candidate.matchRange!]) == "Ｚoë\t  ZHANG")
    let mixed = rule(match: Match(aliases: ["Zhang San", "张三"]))
    #expect(matches([mixed], snapshot(lines: [line("张三 Zhang San 在线")])).count == 1)
}
@Test func headerExcludesSidebarBodyAndSmallText() {
    let person = rule(kind: .person, match: Match(aliases: ["张三"], region: .header), highlight: true)
    #expect(matches([person], snapshot(lines: [line("张三", x: 299)])).isEmpty)
    #expect(matches([person], snapshot(lines: [line("张三", y: 209)])).isEmpty)
    #expect(matches([person], snapshot(lines: [line("张三", height: 11)])).isEmpty)
    #expect(matches([person], snapshot(lines: [line("张三", x: 300, y: 208, height: 12)])).count == 1)
    #expect(matches([person], snapshot(lines: [line("张三", y: 99)])).isEmpty)
}
@Test func headerBandClampsTo80And160() {
    #expect(RuleMatcher.isHeader(line("name", y: 180).rect, in: CGRect(x: 100, y: 100, width: 800, height: 100)))
    #expect(!RuleMatcher.isHeader(line("name", y: 181).rect, in: CGRect(x: 100, y: 100, width: 800, height: 100)))
    #expect(RuleMatcher.isHeader(line("name", y: 260).rect, in: CGRect(x: 100, y: 100, width: 800, height: 2000)))
    #expect(!RuleMatcher.isHeader(line("name", y: 261).rect, in: CGRect(x: 100, y: 100, width: 800, height: 2000)))
}
@Test func titleMatchAndAnywhereHighlight() {
    let person = rule(kind: .person, match: Match(aliases: ["张三"], region: .header), highlight: true)
    let snap = snapshot(title: "和张三聊天", lines: [line("张三", x: 400)])
    let candidate = matches([person], snap).first!
    #expect(candidate.lineIndex == nil)
    #expect(RuleMatcher.highlightRect(for: candidate, in: snap) == snap.textLines[0].rect)
    #expect(RuleMatcher.highlightRect(for: candidate, in: snapshot(title: "张三")) == nil)
    let topic = rule(match: Match(aliases: ["会议"]))
    #expect(matches([topic], snapshot(lines: [line("会议", x: 100, y: 500)])).first?.lineIndex == 0)
}
@Test func highlightUsesCharacterWeights() {
    let text = "ab张三Ｃ!"
    let line = TextLine(text: text, rect: CGRect(x: 10, y: 20, width: 90, height: 18))
    let rect = RuleMatcher.estimatedRect(for: line, range: text.range(of: "张三")!)
    #expect(rect == CGRect(x: 30, y: 20, width: 40, height: 18))
}
@Test func timeRulesRequireAppSwitchAndCorrectWindow() {
    let time = rule(kind: .time, match: Match(when: .lateNight))
    #expect(matches([time], snapshot(), now: date("2026-10-12T23:00:00Z")).count == 1)
    #expect(matches([time], snapshot(), now: date("2026-10-13T04:59:00Z")).count == 1)
    #expect(matches([time], snapshot(), now: date("2026-10-13T05:00:00Z")).isEmpty)
    #expect(matches([time], snapshot(), appChanged: false, now: date("2026-10-12T23:00:00Z")).isEmpty)
    #expect(When.mondayMorning.contains(date("2026-10-12T06:00:00Z"), calendar: utcCalendar))
    #expect(!When.mondayMorning.contains(date("2026-10-12T11:00:00Z"), calendar: utcCalendar))
    #expect(When.fridayEvening.contains(date("2026-10-16T16:00:00Z"), calendar: utcCalendar))
    #expect(!When.fridayEvening.contains(date("2026-10-16T20:00:00Z"), calendar: utcCalendar))
}
@Test func candidatesDeduplicateSortByKindAndNewest() {
    let person = rule("person", kind: .person, match: Match(aliases: ["张三", "张总"], region: .header))
    let old = rule("old", createdAt: epoch.addingTimeInterval(-100))
    let new = rule("new", createdAt: epoch)
    let site = rule("site", kind: .site, match: Match(domains: ["google.com"]))
    let app = rule("app", kind: .app, match: Match(appNames: ["google"]))
    let time = rule("time", kind: .time, match: Match(when: .lateNight))
    let found = matches([old, time, app, person, new, site, person], snapshot(title: "张三张总会议", host: "google.com"), now: date("2026-10-12T23:00:00Z"))
    #expect(found.map { $0.rule.id } == ["person", "new", "old", "site", "app", "time"])
}
@Test func builtinPackLoadsAndEveryRuleValidates() throws {
    let pack = try RuleLoader.loadBuiltin()
    #expect(pack.version == 1)
    #expect(pack.rules.count == 32)
    #expect(pack.generic.keys.sorted() == ["dislike", "like", "neutral"])
    for rule in pack.rules { try RuleLoader.validate(rule) }
    let matcher = RuleMatcher(rules: pack.rules, disabledBuiltinIds: ["builtin.app.dingtalk"])
    let snap = ContextSnapshot(bundleId: "com.alibaba.DingTalkMac", appName: "钉钉", pid: 1,
                               windowFrame: content, contentFrame: content, capturedAt: epoch)
    #expect(!matcher.candidates(in: snap, now: epoch, appChanged: true, hostChanged: true).contains { $0.rule.id == "builtin.app.dingtalk" })
}
