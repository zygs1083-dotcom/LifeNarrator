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
    SpriteScout.targets(in: spriteSnapshot(lines), candidates: [], memory: SpriteMemory(), level: level)
}

@Test func spriteCategoriesAndOriginalRanges() {
    for (category, source, expected) in [
        (TargetCategory.name, spriteLine("张三"), "张三"),
        (.name, spriteLine("Alice Smith"), "Alice Smith"),
        (.deadline, spriteLine("安排：截止周五 18:00 前提交", y: 300), "安排：截止周五 18:00 前提交"),
        (.money, spriteLine("售价 ¥1,299.00 起"), "¥1,299.00"),
        (.action, spriteLine("立即购买", y: 300, role: .button), "立即购买")
    ] {
        let target = scout([source]).first { $0.category == category }
        #expect(target?.text == expected)
        if let target { #expect(String(source.text[target.range]) == expected) }
    }
    #expect(scout([spriteLine("价格　＄１,２９９.００　起")]).first { $0.category == .money }?.text == "＄１,２９９.００")
    #expect(scout([spriteLine("Pay   12 USD today")]).first { $0.category == .money }?.text == "12 USD")
}

@Test func spriteExclusionsAndRemovedCategories() {
    for text in ["超时保护", "ERROR 码表", "12,345 次播放", "今天要不要试试？", "重要事项！", "大标题", "周五之前", "10:32", "截止日期尚未确定", "goodbye tomorrow"] {
        #expect(scout([spriteLine(text, y: 300, height: 24)]).isEmpty, "\(text)")
    }
    #expect(scout([spriteLine("截止周五 18:00", y: 300)]).first?.category == .deadline)
    for source in [spriteLine("¥99", y: 40), spriteLine("¥99", role: .field), spriteLine("¥99", height: 9),
                   spriteLine("alice@example.com ¥99"), spriteLine("+86 138-1234-5678 ¥99"),
                   spriteLine("123456789012 ¥99"), spriteLine("https://example.com ¥99"), spriteLine("www.example.com ¥99"),
                   spriteLine("了解更多", y: 300, role: .link), spriteLine("buying", y: 300, role: .link)] {
        #expect(scout([source]).isEmpty)
    }
    let near = spriteSnapshot([spriteLine("¥99", y: 160)], sensitive: [CGRect(x: 300, y: 200, width: 100, height: 20)])
    #expect(SpriteScout.targets(in: near, candidates: [], memory: SpriteMemory(), level: .lively).isEmpty)
    #expect(scout([spriteLine(String(repeating: "正文", count: 40) + "，仅售 ¥99")]).contains { $0.category == .money })
    let codeApp = spriteSnapshot([spriteLine("¥99")], bundleId: "com.apple.dt.Xcode")
    #expect(SpriteScout.targets(in: codeApp, candidates: [], memory: SpriteMemory(), level: .lively).first?.category == .money)
}

@Test func spriteRulesBypassHeuristicExclusionsAndAnchorTitles() {
    let line = spriteLine("错误", role: .field)
    let topic = rule("topic", match: Match(aliases: ["错误"]))
    let snapshot = spriteSnapshot([line])
    let candidates = RuleMatcher(rules: [topic]).candidates(in: snapshot, now: epoch, appChanged: false, hostChanged: false)
    #expect(SpriteScout.targets(in: snapshot, candidates: candidates, memory: SpriteMemory(), level: .quiet).first?.category == .rule)
    var titled = spriteSnapshot([spriteLine("Test Title")])
    titled.windowTitle = "test title"
    let app = Candidate(rule: rule("app", kind: .app, match: Match(bundleIds: ["test"])))
    let target = SpriteScout.targets(in: titled, candidates: [app], memory: SpriteMemory(), level: .lively).first!
    #expect(target.lineIndex == 0)
    #expect(target.text == "Test Title")
    titled.textLines = []
    #expect(SpriteScout.targets(in: titled, candidates: [app], memory: SpriteMemory(), level: .quiet).first?.lineIndex == -1)
}

@Test func spriteScoringSortingAndDeduplication() {
    #expect(scout([spriteLine("¥99")]).first?.score == 6)
    #expect(scout([spriteLine("¥99", x: 50)]).first?.score == 4)
    let snapshot = spriteSnapshot([spriteLine("¥99")])
    #expect(SpriteScout.targets(in: snapshot, candidates: [], memory: SpriteMemory(), level: .lively).first?.score == 6)
    #expect(scout([spriteLine("¥99"), spriteLine("￥99", y: 350)]).count == 1)
    #expect(scout([spriteLine("¥88", y: 350), spriteLine("¥99", y: 300, height: 20), spriteLine("¥77", y: 250, height: 20)]).map(\.text) == ["¥77", "¥99", "¥88"])
}

@Test func spriteMediaFullScreenCountsContentLinesInsteadOfTargets() {
    let lines = (0..<13).map { spriteLine("ordinary prose \($0)", y: 250 + CGFloat($0) * 20) }
    #expect(SpriteScout.isMediaFullScreen(spriteSnapshot(Array(lines.prefix(12)), fullScreen: true)))
    #expect(!SpriteScout.isMediaFullScreen(spriteSnapshot(lines, fullScreen: true)))
    #expect(!SpriteScout.isMediaFullScreen(spriteSnapshot(lines)))
    #expect(SpriteScout.isMediaFullScreen(spriteSnapshot(lines, fullScreen: true, source: .ocr)))
    var ignored = lines
    ignored[12].rect.size.height = 9
    #expect(SpriteScout.isMediaFullScreen(spriteSnapshot(ignored, fullScreen: true)))
    ignored[12] = spriteLine("chrome", y: 40)
    #expect(SpriteScout.isMediaFullScreen(spriteSnapshot(ignored, fullScreen: true)))
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

@Test func spriteHeaderNavigationIsNotNames() {
    let nav = ["首页", "新闻", "视频", "图片"].enumerated().map { spriteLine($0.element, x: 300 + CGFloat($0.offset) * 100) }
    #expect(!scout(nav).contains { $0.category == .name })
    #expect(scout([spriteLine("张三"), spriteLine("李四", x: 500)]).filter { $0.category == .name }.count == 2)
}
