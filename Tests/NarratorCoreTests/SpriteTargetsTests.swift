import Foundation
import Testing
@testable import NarratorCore

private let spriteContent = CGRect(x: 0, y: 50, width: 800, height: 700)
private func spriteLine(_ text: String, x: CGFloat = 300, y: CGFloat = 100, height: CGFloat = 16, role: TextRole = .text) -> TextLine {
    TextLine(text: text, rect: CGRect(x: x, y: y, width: 180, height: height), role: role)
}
private func spriteSnapshot(_ lines: [TextLine], bundleId: String = "test", sensitive: [CGRect] = [],
                            fullScreen: Bool = false, source: TextSource = .ax, now: Date = epoch) -> ContextSnapshot {
    ContextSnapshot(bundleId: bundleId, appName: "Test", pid: 1, windowFrame: CGRect(x: 0, y: 0, width: 800, height: 750),
                    contentFrame: spriteContent, textLines: lines, textSource: source, sensitiveRects: sensitive,
                    fullScreen: fullScreen, capturedAt: now)
}
private func scout(_ lines: [TextLine], level: Liveliness = .lively) -> [SpriteTarget] {
    SpriteScout.targets(in: spriteSnapshot(lines), candidates: [], memory: SpriteMemory(), onScreen: [], level: level)
}

@Test func spriteCategoriesAndOriginalRanges() {
    let examples: [(TargetCategory, TextLine, String)] = [
        (.name, spriteLine("张三"), "张三"),
        (.name, spriteLine("Alice Smith"), "Alice Smith"),
        (.alert, spriteLine("完成，构建失败，稍后再试"), "构建失败"),
        (.deadline, spriteLine("安排：截止周五 18:00 前提交"), "安排：截止周五 18:00 前提交"),
        (.money, spriteLine("售价 ¥1,299.00 起"), "¥1,299.00"),
        (.action, spriteLine("立即购买", y: 300, role: .button), "立即购买"),
        (.question, spriteLine("今天吃什么？"), "今天吃什么？"),
        (.stat, spriteLine("已有 12,345 次阅读"), "12,345 次"),
        (.emphasis, spriteLine("马上开始！"), "马上开始！"),
        (.heading, spriteLine("这里是新篇章", y: 300, height: 24), "这里是新篇章"),
    ]
    for (category, line, expected) in examples {
        let lines = [line, spriteLine("普通的正文。", y: 400), spriteLine("其他正文。", y: 450)]
        let targets = scout(lines)
        let target = targets.first { $0.category == category }
        #expect(target?.text == expected)
        if let target { #expect(String(line.text[target.range]) == expected) }
    }
    let deadlineLine = spriteLine("截止周五 18:00 前提交")
    #expect(scout([deadlineLine]).first?.text == deadlineLine.text)
    let fullwidth = spriteLine("价格　＄１,２９９.００　起")
    #expect(scout([fullwidth]).first { $0.category == .money }?.text == "＄１,２９９.００")
    let folded = spriteLine("Pay   12 USD today")
    #expect(scout([folded]).first { $0.category == .money }?.text == "12 USD")
}

@Test func spriteExclusions() {
    let excluded = [
        spriteLine("错误", y: 40), spriteLine("错误", role: .field), spriteLine("错误", height: 9),
        spriteLine("alice@example.com 错误"), spriteLine("+86 138-1234-5678 错误"),
        spriteLine("123456789012 错误"), spriteLine("https://example.com 错误"), spriteLine("www.example.com 错误"),
        spriteLine(String(repeating: "正文内容", count: 16)), spriteLine(String(repeating: "ordinary prose ", count: 10)),
        spriteLine("设置"), spriteLine("Ｓｅｔｔｉｎｇｓ"), spriteLine("sign in"), spriteLine("了解更多", y: 300, role: .link),
        spriteLine("10:32"), spriteLine("let urgent = 100%;"), spriteLine("value = (100%);"),
    ]
    for line in excluded { #expect(scout([line]).isEmpty, "\(line.text)") }
    let near = spriteSnapshot([spriteLine("错误", y: 160)], sensitive: [CGRect(x: 300, y: 200, width: 100, height: 20)])
    #expect(SpriteScout.targets(in: near, candidates: [], memory: SpriteMemory(), onScreen: [], level: .lively).isEmpty)
    let far = spriteSnapshot([spriteLine("错误", y: 100)], sensitive: near.sensitiveRects)
    #expect(!SpriteScout.targets(in: far, candidates: [], memory: SpriteMemory(), onScreen: [], level: .lively).isEmpty)
    #expect(scout([spriteLine("截止 18:00")]).contains { $0.category == .deadline })
    #expect(!scout([spriteLine("截止日期尚未确定")]).contains { $0.category == .deadline })
    #expect(!scout([spriteLine("goodbye tomorrow")]).contains { $0.category == .deadline })
    #expect(!scout([spriteLine("errorless warningly")]).contains { $0.category == .alert })
    #expect(!scout([spriteLine("buying", role: .link)]).contains { $0.category == .action })
}

@Test func spriteLongTextAndCodeKeepOnlyAllowedCategories() {
    let long = String(repeating: "正文", count: 40)
    for (suffix, category) in [("，失败请重试", TargetCategory.alert), ("，截止明天前提交", .deadline), ("，仅售 ¥99", .money), ("，已达 10%", .stat)] {
        let targets = scout([spriteLine(long + suffix)])
        #expect(targets.contains { $0.category == category })
        #expect(!targets.contains { $0.category == .name || $0.category == .heading })
        #expect(targets.allSatisfy { $0.text.count <= 30 })
    }
    let code = spriteLine("let result = failed(); 100%")
    #expect(scout([code]).map(\.category) == [.alert])
    let snapshot = spriteSnapshot([spriteLine("失败"), spriteLine("¥99", y: 300), spriteLine("张三", y: 130)], bundleId: "com.apple.dt.Xcode")
    let person = rule("person", kind: .person, match: Match(aliases: ["张三"], region: .header))
    let candidates = RuleMatcher(rules: [person]).candidates(in: snapshot, now: epoch, appChanged: true, hostChanged: false)
    let targets = SpriteScout.targets(in: snapshot, candidates: candidates, memory: SpriteMemory(), onScreen: [], level: .lively)
    #expect(Set(targets.map(\.category)) == [.rule, .alert])
    #expect(targets.first?.candidate?.rule.id == person.id)
}

@Test func spriteRulesBypassHeuristicExclusionsAndAnchorTitles() {
    let line = spriteLine("错误", role: .field)
    let topic = rule("topic", match: Match(aliases: ["错误"]))
    let snapshot = spriteSnapshot([line])
    let candidates = RuleMatcher(rules: [topic]).candidates(in: snapshot, now: epoch, appChanged: false, hostChanged: false)
    #expect(SpriteScout.targets(in: snapshot, candidates: candidates, memory: SpriteMemory(), onScreen: [], level: .quiet).first?.category == .rule)
    var titled = spriteSnapshot([spriteLine("Test Title")])
    titled.windowTitle = "test title"
    let app = Candidate(rule: rule("app", kind: .app, match: Match(bundleIds: ["test"])))
    let target = SpriteScout.targets(in: titled, candidates: [app], memory: SpriteMemory(), onScreen: [], level: .lively).first!
    #expect(target.lineIndex == 0)
    #expect(target.text == "Test Title")
    titled.textLines = []
    #expect(SpriteScout.targets(in: titled, candidates: [app], memory: SpriteMemory(), onScreen: [], level: .quiet).first?.lineIndex == -1)
}

@Test func spriteScoringSortingThresholdsAndDeduplication() {
    #expect(scout([spriteLine("¥99")]).first?.score == 6)
    #expect(scout([spriteLine("¥99", x: 50)]).first?.score == 4)
    let snapshot = spriteSnapshot([spriteLine("¥99")])
    let onScreen = scout(snapshot.textLines)
    #expect(SpriteScout.targets(in: snapshot, candidates: [], memory: SpriteMemory(), onScreen: onScreen, level: .lively).first?.score == 4)
    let weak = [spriteLine("12%", x: 50, height: 24), spriteLine("普通正文。", y: 400), spriteLine("其他正文。", y: 450)]
    #expect(scout(weak).isEmpty)
    #expect(scout(weak, level: .rowdy).first?.score == 3)
    #expect(scout([spriteLine("构建失败")], level: .quiet).isEmpty)
    let heading = [spriteLine("第一个章节", y: 300, height: 24), spriteLine("普通正文。", y: 400), spriteLine("其他正文。", y: 450)]
    #expect(scout(heading).first { $0.category == .heading }?.score == 4)
    #expect(!scout([spriteLine("第一个章节", y: 300)]).contains { $0.category == .heading })
    let duplicates = scout([spriteLine("¥99", y: 300), spriteLine("￥99", y: 350)])
    #expect(duplicates.count == 1)
    let heights = scout([spriteLine("¥88", y: 350), spriteLine("¥99", y: 300, height: 20), spriteLine("¥77", y: 250, height: 20)])
    #expect(heights.map(\.text) == ["¥77", "¥99", "¥88"])
    let short = scout([spriteLine("Is this a question?")]).first!
    let longer = scout([spriteLine("Is this a longer question?")]).first!
    #expect(short.score == longer.score + 1)
}

@Test func spriteBatchDiversity() {
    let snapshot = spriteSnapshot([spriteLine("错误", y: 300), spriteLine("¥99", y: 315), spriteLine("¥88", y: 340),
                                   spriteLine("截止明天", y: 400), spriteLine("100%", y: 450)])
    let targets = SpriteScout.targets(in: snapshot, candidates: [], memory: SpriteMemory(), onScreen: [], level: .lively)
    let selected = SpriteScout.diverse(targets, in: snapshot, count: 2)
    #expect(selected.count == 2)
    #expect(selected.map(\.category) == [.alert, .money])
    #expect(selected.map(\.text) == ["错误", "¥88"])
    let rects = selected.map { RuleMatcher.estimatedRect(for: snapshot.textLines[$0.lineIndex], range: $0.range) }
    #expect(abs(rects[0].minY - rects[1].minY) >= 24)
    #expect(!rects[0].insetBy(dx: -8, dy: -8).intersects(rects[1].insetBy(dx: -8, dy: -8)))
    #expect(SpriteScout.diverse(targets, in: snapshot, count: 0).isEmpty)
    let closeFrames = spriteSnapshot([spriteLine("错误", y: 300), spriteLine("¥99", y: 335), spriteLine("¥88", y: 380)])
    let closeTargets = SpriteScout.targets(in: closeFrames, candidates: [], memory: SpriteMemory(), onScreen: [], level: .lively)
    #expect(SpriteScout.diverse(closeTargets, in: closeFrames, count: 2).map(\.text) == ["错误", "¥88"])
}

@Test func spriteMediaFullScreen() {
    let lines = (0..<7).map { spriteLine("¥\($0 + 10)", y: 250 + CGFloat($0) * 40) }
    #expect(SpriteScout.isMediaFullScreen(spriteSnapshot(Array(lines.prefix(5)), fullScreen: true)))
    #expect(!SpriteScout.isMediaFullScreen(spriteSnapshot(lines, fullScreen: true)))
    #expect(!SpriteScout.isMediaFullScreen(spriteSnapshot(lines)))
    #expect(SpriteScout.isMediaFullScreen(spriteSnapshot(lines, fullScreen: true, source: .ocr)))
}

@Test func spriteTextRoleBackwardDecodingAndSnapshotFields() throws {
    let line = spriteLine("购买", role: .button)
    let encoder = JSONEncoder()
    var json = try #require(JSONSerialization.jsonObject(with: encoder.encode(line)) as? [String: Any])
    json.removeValue(forKey: "role")
    let decoded = try JSONDecoder().decode(TextLine.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.role == .text)
    #expect(try JSONDecoder().decode(TextLine.self, from: encoder.encode(line)) == line)
    var snapshot = spriteSnapshot([line])
    #expect(snapshot.sensitiveRects.isEmpty && !snapshot.secureFocused && !snapshot.fullScreen)
    snapshot.sensitiveRects = [line.rect]; snapshot.secureFocused = true; snapshot.fullScreen = true
    let result = try JSONDecoder().decode(ContextSnapshot.self, from: encoder.encode(snapshot))
    #expect(result.sensitiveRects == snapshot.sensitiveRects && result.secureFocused && result.fullScreen)
}
