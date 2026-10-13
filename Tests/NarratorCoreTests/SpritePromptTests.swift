import Foundation
import Testing
@testable import NarratorCore

func semanticsSnapshot(_ texts: [String]) -> ContextSnapshot {
    ContextSnapshot(bundleId: "fixture", appName: "Fixture", pid: 1, windowTitle: "Manual",
        windowFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
        contentFrame: CGRect(x: 0, y: 50, width: 1000, height: 950),
        textLines: texts.enumerated().map { TextLine(text: $0.element, rect: CGRect(x: 300, y: 100 + $0.offset * 16, width: 500, height: 16)) },
        textSource: .ax, capturedAt: epoch)
}

@Test func spriteScreenFiltersAndKeepsOriginalLineMapping() {
    var snapshot = semanticsSnapshot(["chrome", "draft", "near password", "tiny", "字", "Kept text", "Ｋｅｐｔ   TEXT", "Another line"])
    snapshot.textLines[0].rect.origin.y = 40
    snapshot.textLines[1].role = .field
    snapshot.textLines[2].rect.origin.x = 10
    snapshot.sensitiveRects = [CGRect(x: 10, y: 140, width: 10, height: 16)]
    snapshot.textLines[3].rect.size.height = 9
    let screen = SpritePrompt.screen(in: snapshot)
    #expect(screen.lines.map(\.lineIndex) == [5, 7])
    #expect(screen.text == "0| Kept text\n1| Another line")
}

@Test func spriteScreenRedactsPrivacySubstringsAndDropsPrivacyOnlyLines() {
    let screen = SpritePrompt.screen(in: semanticsSnapshot([
        "邮箱 alice@example.com 已验证", "电话 +86 138-1234-5678 已验证", "编号 123456789012 已验证",
        "参考 https://example.com/private/path 下一步", "站点 www.example.com/private 下一步", "alice@example.com", "(123456789012)",
        "备用电话 ＋８６ １３８－１２３４－５６７８ 已验证"
    ]))
    #expect(screen.lines.map(\.lineIndex) == [0, 1, 2, 3, 4, 7])
    #expect(screen.lines.map(\.text) == ["邮箱 *** 已验证", "电话 *** 已验证", "编号 *** 已验证", "参考 *** 下一步", "站点 *** 下一步", "备用电话 *** 已验证"])
}

@Test func spriteScreenAppliesAllThreeTruncationStepsAndAccountsForLineNumbers() {
    let snapshot = semanticsSnapshot((0..<50).map { "第\($0)行" + String(repeating: "字", count: 100) })
    let sixty = SpritePrompt.screen(in: snapshot, budget: 4000)
    #expect(sixty.lines.count == 50)
    #expect(sixty.lines.allSatisfy { SpritePrompt.estimatedTokens($0.text) <= 60 && $0.text.hasSuffix("…") })
    let thirty = SpritePrompt.screen(in: snapshot, budget: 1700)
    #expect(thirty.lines.count == 50)
    #expect(thirty.lines.allSatisfy { SpritePrompt.estimatedTokens($0.text) <= 30 && $0.text.hasSuffix("…") })
    let forty = SpritePrompt.screen(in: semanticsSnapshot((0..<50).map { "\($0)" + String(repeating: "字", count: 18) }))
    #expect(forty.lines.count == 40)
    let final = SpritePrompt.screen(in: snapshot)
    #expect(final.lines.count <= 40)
    #expect(final.tokens <= 700)
    #expect(final.lines.allSatisfy { SpritePrompt.estimatedTokens($0.text) <= 30 })
    #expect(final.lines.map(\.lineIndex) == Array(0..<final.lines.count))
    #expect(SpritePrompt.estimatedTokens("你好") == 1.5)
    #expect(abs(SpritePrompt.estimatedTokens("hello") - 1.5) < 0.001)
}

@Test func spritePromptAsksToFillOnlyForLargeCounts() {
    let snapshot = ContextSnapshot(bundleId: "test", appName: "Test", pid: 1, windowFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                   contentFrame: CGRect(x: 0, y: 50, width: 800, height: 550),
                                   textLines: [TextLine(text: "第一行内容", rect: CGRect(x: 10, y: 100, width: 200, height: 16))],
                                   textSource: .ax, capturedAt: Date(timeIntervalSince1970: 0))
    let screen = SpritePrompt.screen(in: snapshot)
    let few = GenerationPrompts.spriteMarks(app: "A", title: "T", screen: screen, exclude: [], persona: .sharp, lang: .zh, k: 4)
    let many = GenerationPrompts.spriteMarks(app: "A", title: "T", screen: screen, exclude: [], persona: .sharp, lang: .zh, k: 8)
    #expect(!few.user.contains("尽量挑满"))
    #expect(many.user.contains("尽量挑满 8 处"))
}
