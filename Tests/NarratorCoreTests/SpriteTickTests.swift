import Foundation
import Testing
@testable import NarratorCore

private func tickAttempts(_ snapshot: ContextSnapshot = semanticsSnapshot(["售价 ¥99", "截止周五 18:00", "立即购买"]),
                          candidates: [Candidate] = [], memory: SpriteMemory = SpriteMemory(),
                          level: Liveliness = .lively, hasModel: Bool = true, allowed: Bool = true,
                          switching: Bool = true, revisit: Bool = true,
                          scheduler: Scheduler = Scheduler(settings: .init(level: .lively)), now: Date = epoch) -> [SpriteTick.Attempt] {
    SpriteTick.attempts(in: snapshot, candidates: candidates, memory: memory, level: level, switching: switching,
                       scheduler: scheduler, revisitAllowed: revisit, screen: SpritePrompt.screen(in: snapshot),
                       screenKey: 7, hasModel: hasModel, requestAllowed: allowed, now: now)
}

@Test func tickFourLayersPreferRuleCacheRequestLeastRecentThenRevisit() {
    let snapshot = semanticsSnapshot(["售价 ¥99", "截止周五 18:00"])
    let candidate = Candidate(rule: rule("price"), lineIndex: 0, matchRange: snapshot.textLines[0].text.startIndex..<snapshot.textLines[0].text.endIndex)
    #expect(tickAttempts(snapshot, candidates: [candidate]).map(\.reason) == ["rule", "request"])
    var memory = SpriteMemory()
    let key = SpriteMemory.Key(bundleId: snapshot.bundleId, text: "截止周五")
    memory.cache(key: key, quip: quip("模型句"), lineHint: 1, now: epoch)
    let cache = tickAttempts(snapshot, candidates: [candidate], memory: memory)
    #expect(cache.map(\.reason) == ["rule", "cache"])
    #expect(cache.last?.mark?.quip.text == "模型句")
    #expect(cache.last?.mark?.lineIndex == 1)
    memory.mark(key: key, quip: quip("模型句"), lineHint: 1, now: epoch.addingTimeInterval(-59))
    #expect(tickAttempts(snapshot, memory: memory).map(\.reason) == ["request"])
    #expect(tickAttempts(snapshot, memory: memory, allowed: false).map(\.reason) == ["revisit"])
    memory.mark(key: key, quip: quip("模型句"), lineHint: 1, now: epoch.addingTimeInterval(-60))
    #expect(tickAttempts(snapshot, memory: memory, allowed: false).map(\.reason) == ["least-recent"])
    #expect(tickAttempts(snapshot, memory: memory, allowed: false).first?.mark?.quip.text == "模型句")
    #expect(tickAttempts(snapshot, memory: memory, allowed: false, switching: false).isEmpty)
    #expect(tickAttempts(snapshot, allowed: false, revisit: false).isEmpty)
    #expect(tickAttempts(snapshot, memory: memory, now: epoch.addingTimeInterval(1800)).first?.reason == "request")
    #expect(tickAttempts(snapshot, memory: memory, allowed: false, now: epoch.addingTimeInterval(1800)).first?.reason == "least-recent")
}

@Test func tickCacheReplaysAfterTTLAndDoesNotReplayMissingOrUnsentQuotes() {
    let snapshot = semanticsSnapshot(["first quote", "second quote"])
    var memory = SpriteMemory(level: .rowdy)
    let first = SpriteMemory.Key(bundleId: snapshot.bundleId, text: "first quote")
    memory.cache(key: first, quip: quip("一句"), lineHint: 0, now: epoch)
    memory.mark(key: first, quip: quip("一句"), lineHint: 0, now: epoch)
    #expect(!tickAttempts(snapshot, memory: memory, level: .rowdy, now: epoch.addingTimeInterval(899)).contains { $0.reason == "cache" })
    #expect(tickAttempts(snapshot, memory: memory, level: .rowdy, now: epoch.addingTimeInterval(900)).first?.reason == "cache")
    memory.cache(key: .init(bundleId: snapshot.bundleId, text: "missing quote"), quip: quip("丢弃"), lineHint: 1, now: epoch)
    var filtered = snapshot
    filtered.textLines[0].role = .field
    #expect(tickAttempts(filtered, memory: memory).map(\.reason) == ["request"])
}

@Test func tickRequestCountsRespectBothScreenLimits() {
    for (level, limit) in [(Liveliness.lively, 2), (.rowdy, 3)] {
        var memory = SpriteMemory(level: level)
        for _ in 0..<limit {
            #expect(tickAttempts(memory: memory, level: level).first?.reason == "request")
            memory.recordRequest(key: 7, now: epoch)
        }
        #expect(tickAttempts(memory: memory, level: level).first?.reason == "revisit")
    }
}

@Test func tickWithoutModelUsesLocalCategoriesAndQuietOnlyRules() {
    var snapshot = semanticsSnapshot(["张三", "售价 ¥99", "截止周五 18:00", "立即购买", "超时保护", "ERROR 码表", "12,345 次播放", "今天要不要试试？", "重要事项！"])
    snapshot.textLines[3].role = .button
    snapshot.textLines[3].rect.origin.y = 280
    for i in 4..<snapshot.textLines.count { snapshot.textLines[i].rect.origin.y = CGFloat(300 + i * 20) }
    let local = tickAttempts(snapshot, hasModel: false)
    #expect(Set(local.compactMap { $0.target?.category }) == [.name, .money, .deadline, .action])
    #expect(local.allSatisfy { $0.reason == "local" })
    #expect(local.count >= 1 + SpriteTick.localBurst(level: .lively).count)
    #expect(local.count >= 1 + SpriteTick.localBurst(level: .rowdy).count)
    #expect(tickAttempts(snapshot, level: .quiet, hasModel: false).isEmpty)
    let candidate = Candidate(rule: rule("name"), lineIndex: 0, matchRange: snapshot.textLines[0].text.startIndex..<snapshot.textLines[0].text.endIndex)
    #expect(tickAttempts(snapshot, candidates: [candidate], level: .quiet).map(\.reason) == ["rule"])
}

@Test func tickLocalLeastRecentRotatesAndRevisitAnchorsTitle() {
    var snapshot = semanticsSnapshot(["售价 ¥99"])
    var memory = SpriteMemory()
    memory.mark(key: .init(bundleId: snapshot.bundleId, text: "¥99"), quip: quip("旧句"), now: epoch.addingTimeInterval(-60))
    #expect(tickAttempts(snapshot, memory: memory, hasModel: false).first?.reason == "least-recent")
    snapshot.textLines = [line("Manual", y: 40)]
    #expect(tickAttempts(snapshot).first?.reason == "revisit")
    #expect(tickAttempts(snapshot).first?.target?.lineIndex == 0)
    #expect(tickAttempts(snapshot, revisit: false).isEmpty)
}

@Test func tickNoTextAllowsOnlyAppSiteRulesWithCooldown() {
    var snapshot = semanticsSnapshot([])
    snapshot.textSource = .none
    let candidates = [Candidate(rule: rule("person", kind: .person)), Candidate(rule: rule("topic")), Candidate(rule: rule("app", kind: .app))]
    #expect(tickAttempts(snapshot, candidates: candidates, revisit: false).compactMap { $0.target?.candidate?.rule.id } == ["app"])
    var scheduler = Scheduler(settings: .init(level: .lively))
    scheduler.recordShown(ruleID: "app", now: epoch.addingTimeInterval(-60))
    #expect(tickAttempts(snapshot, candidates: candidates, revisit: false, scheduler: scheduler).isEmpty)
}

@Test func tickSilenceAppliesToTypingSecureMediaMovementAndSmallWindows() {
    var snapshot = semanticsSnapshot(["body text"])
    #expect(SpriteTick.quietReason(in: snapshot, typing: true, moving: false) == "typing")
    snapshot.secureFocused = true
    #expect(SpriteTick.quietReason(in: snapshot, typing: false, moving: false) == "secure")
    snapshot.secureFocused = false
    snapshot.fullScreen = true
    #expect(SpriteTick.quietReason(in: snapshot, typing: false, moving: false) == "media")
    snapshot.fullScreen = false
    #expect(SpriteTick.quietReason(in: snapshot, typing: false, moving: true) == "moving")
    snapshot.windowFrame.size.width = 359
    #expect(SpriteTick.quietReason(in: snapshot, typing: false, moving: false) == "small")
    snapshot.windowFrame.size.width = 800
    #expect(SpriteTick.quietReason(in: snapshot, typing: false, moving: false) == nil)
}

@Test func tickTimingAndCapsFollowLiveliness() {
    for (level, release, followup, requests, interval, burst, screen) in [
        (Liveliness.quiet, 0.0, 0.0, 0, 0.0, [Double](), 0),
        (.lively, 3, 20, 2, 8, [3], 8), (.rowdy, 1.5, 10, 3, 5, [1.5, 3], 14)
    ] {
        #expect(SpriteTick.releaseGap(level: level) == release)
        #expect(SpriteTick.followupDelay(level: level) == followup)
        #expect(SpriteTick.requestsPerScreen(level: level) == requests)
        #expect(SpriteTick.windowRequestInterval(level: level) == interval)
        #expect(SpriteTick.localBurst(level: level) == burst)
        #expect(SpriteTick.screenLimit(level: level) == screen)
    }
}

@Test func spriteModelBudgetUsesSlidingWindowAndConfiguredLimit() {
    var budget = SpriteModelBudget(perMinute: 4)
    for (second, expected) in [(0.0, true), (10, true), (20, true), (30, true), (59.999, false), (60, true), (69.999, false), (70, true), (120, true)] {
        #expect(budget.begin(now: epoch.addingTimeInterval(second)) == expected)
    }
    var rowdy = SpriteModelBudget(perMinute: 6)
    for _ in 0..<6 { let began = rowdy.begin(now: epoch); #expect(began) }
    let seventh = rowdy.begin(now: epoch)
    #expect(!seventh)
}

@Test func spriteAPIRequestCarriesTokenLimitAndSystemUserMessages() throws {
    let request = try OpenAICompatibleClient(baseURL: URL(string: "https://example.test")!, model: "fixture")
        .makeRequest(system: "system", prompt: "screen", schema: GenerationPrompts.spriteMarksSchema, maxTokens: SpriteGenerator.maxTokens)
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    #expect(body["max_tokens"] as? Int == 450)
    #expect((body["messages"] as? [[String: String]]) == [["role":"system","content":"system"], ["role":"user","content":"screen"]])
}
