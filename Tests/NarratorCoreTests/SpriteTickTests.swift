import Foundation
import Testing
@testable import NarratorCore

private func feedSnapshot() -> ContextSnapshot {
    let lines = ["构建失败", "¥1,299.00", "截止周五 18:00 前提交"].enumerated().map {
        TextLine(text: $0.element, rect: CGRect(x: 300, y: 100 + $0.offset * 80, width: 180, height: 16))
    }
    return ContextSnapshot(bundleId: "fixture", appName: "Fixture", pid: 1, windowTitle: "Fixture Feed",
                           windowFrame: CGRect(x: 0, y: 0, width: 800, height: 700),
                           contentFrame: CGRect(x: 0, y: 50, width: 800, height: 650),
                           textLines: lines, textSource: .ax, capturedAt: epoch)
}

private func tickAttempts(_ snapshot: ContextSnapshot = feedSnapshot(), candidates: [Candidate] = [],
                          memory: SpriteMemory = SpriteMemory(), level: Liveliness = .lively,
                          switching: Bool = true, scheduler: Scheduler = Scheduler(settings: .init(level: .lively)),
                          revisit: Bool = true, now: Date = epoch) -> [SpriteTick.Attempt] {
    SpriteTick.attempts(in: snapshot, candidates: candidates, memory: memory, onScreen: [], level: level,
                        switching: switching, scheduler: scheduler, revisitAllowed: revisit, now: now)
}

@Test func tickPrefersFreshTargetsAndOnlyFallsBackOnSwitches() {
    let attempts = tickAttempts()
    #expect(attempts.first?.target.category == .alert)
    #expect(attempts.first?.reason == "fresh")
    #expect(attempts.last?.target.category == .revisit)
    #expect(!tickAttempts(switching: false).contains { $0.target.category == .revisit })
    #expect(tickAttempts(level: .quiet).isEmpty)
}

@Test func tickLeastRecentRequiresAllTargetsSeenAndTenSeconds() {
    let snapshot = feedSnapshot()
    let targets = SpriteScout.targets(in: snapshot, candidates: [], memory: SpriteMemory(), onScreen: [], level: .lively)
    var memory = SpriteMemory()
    for (i, target) in targets.enumerated() {
        memory.mark(key: .init(bundleId: snapshot.bundleId, text: target.text), quip: quip("台词"),
                    now: epoch.addingTimeInterval(Double(-40 + i * 5)))
    }
    let attempts = tickAttempts(memory: memory)
    #expect(attempts.first?.reason == "least-recent")
    #expect(attempts.first?.target.text == targets[0].text)
    #expect(attempts.filter { $0.reason == "least-recent" }.map(\.target.text) == targets.map(\.text))
    #expect(attempts.first?.ignoresRuleCooldown == true)
    #expect(tickAttempts(memory: memory, switching: false).isEmpty)
    memory.mark(key: .init(bundleId: snapshot.bundleId, text: targets[0].text), quip: quip("新台词"), now: epoch)
    #expect(!tickAttempts(memory: memory).filter { $0.reason == "least-recent" }.contains { $0.target.text == targets[0].text })
    var onlyOneMarked = SpriteMemory()
    onlyOneMarked.mark(key: .init(bundleId: snapshot.bundleId, text: targets[0].text), quip: quip("台词"), now: epoch.addingTimeInterval(-20))
    #expect(!tickAttempts(memory: onlyOneMarked).contains { $0.reason == "least-recent" })
}

@Test func tickDeclinedTargetsStayOutOfRepeatLayerButRulesRemain() {
    let snapshot = feedSnapshot()
    var memory = SpriteMemory()
    for target in SpriteScout.targets(in: snapshot, candidates: [], memory: SpriteMemory(), onScreen: [], level: .lively) {
        memory.decline(key: .init(bundleId: snapshot.bundleId, text: target.text), now: epoch)
    }
    #expect(tickAttempts(memory: memory).map(\.target.category) == [.revisit])
    let line = snapshot.textLines[0]
    let candidate = Candidate(rule: rule("alert-rule"), lineIndex: 0, matchRange: line.text.startIndex..<line.text.endIndex)
    #expect(tickAttempts(candidates: [candidate], memory: memory).first?.target.category == .rule)
}

@Test func tickRepeatIgnoresOnlyRuleCooldown() {
    var snapshot = feedSnapshot()
    snapshot.textLines = [snapshot.textLines[0]]
    let line = snapshot.textLines[0]
    let candidate = Candidate(rule: rule("alert-rule"), lineIndex: 0, matchRange: line.text.startIndex..<line.text.endIndex)
    var memory = SpriteMemory()
    memory.mark(key: .init(bundleId: snapshot.bundleId, text: line.text), quip: quip("台词"), now: epoch.addingTimeInterval(-20))
    var scheduler = Scheduler(settings: .init(level: .lively))
    scheduler.recordShown(ruleID: candidate.rule.id, now: epoch.addingTimeInterval(-20))
    let repeatAttempt = tickAttempts(snapshot, candidates: [candidate], memory: memory, scheduler: scheduler).first!
    #expect(repeatAttempt.reason == "least-recent")
    #expect(!scheduler.canShow(ruleID: candidate.rule.id, now: epoch))
    #expect(scheduler.canShow(ruleID: nil, now: epoch))
    scheduler.recordShown(ruleID: nil, now: epoch)
    #expect(!scheduler.canShow(ruleID: nil, now: epoch.addingTimeInterval(1)))
}

@Test func tickNoTextAllowsOnlyAppSiteRulesWithCooldown() {
    var snapshot = feedSnapshot()
    snapshot.textSource = .none
    snapshot.textLines = []
    let candidates = [Candidate(rule: rule("person", kind: .person)),
                      Candidate(rule: rule("topic", kind: .topic)),
                      Candidate(rule: rule("time", kind: .time)),
                      Candidate(rule: rule("app", kind: .app))]
    let attempts = tickAttempts(snapshot, candidates: candidates, revisit: false)
    #expect(attempts.map(\.target.candidate?.rule.id) == ["app"])
    #expect(attempts[0].target.lineIndex == -1)
    #expect(!attempts[0].ignoresRuleCooldown)
    var memory = SpriteMemory()
    memory.mark(key: .init(bundleId: snapshot.bundleId, text: attempts[0].target.text), quip: quip("台词"), now: epoch.addingTimeInterval(-20))
    let returning = tickAttempts(snapshot, candidates: candidates, memory: memory, revisit: false)
    #expect(returning.count == 1)
    #expect(!returning[0].ignoresRuleCooldown)
    var scheduler = Scheduler(settings: .init(level: .lively))
    scheduler.recordShown(ruleID: "app", now: epoch.addingTimeInterval(-20))
    #expect(!scheduler.canShow(ruleID: returning[0].target.candidate?.rule.id, now: epoch))
}

@Test func tickRevisitAnchorsTitleAndCanBeSuppressed() {
    var snapshot = feedSnapshot()
    snapshot.textLines = [TextLine(text: "Fixture Feed", rect: CGRect(x: 300, y: 25, width: 150, height: 16))]
    let attempts = tickAttempts(snapshot)
    #expect(attempts.count == 1)
    #expect(attempts[0].target.category == .revisit)
    #expect(attempts[0].target.lineIndex == 0)
    #expect(tickAttempts(snapshot, revisit: false).isEmpty)
    snapshot.textLines = []
    #expect(tickAttempts(snapshot).last?.target.lineIndex == -1)
}

@Test func tickSilenceAppliesToTypingSecureMediaMovementAndSmallWindows() {
    var snapshot = feedSnapshot()
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
    #expect(SpriteTick.burstDelays(level: .quiet).isEmpty)
    #expect(SpriteTick.burstDelays(level: .lively) == [1.5])
    #expect(SpriteTick.burstDelays(level: .rowdy) == [1, 2])
    #expect(SpriteTick.screenLimit(level: .lively) == 6)
    #expect(SpriteTick.screenLimit(level: .rowdy) == 12)
    var random = SystemRandomNumberGenerator()
    #expect(SpriteTick.idleDelay(level: .quiet, using: &random) == nil)
    for _ in 0..<100 {
        #expect((5...11).contains(SpriteTick.idleDelay(level: .lively, using: &random)!))
        #expect((2.5...5.5).contains(SpriteTick.idleDelay(level: .rowdy, using: &random)!))
    }
}

@Test func spriteModelBudgetUsesSlidingWindowAndCountsOnlyStartedRequests() {
    var budget = SpriteModelBudget()
    for (second, expected) in [(0.0, true), (10, true), (20, true), (30, true), (59.999, false),
                               (60, true), (69.999, false), (70, true), (120, true)] {
        let began = budget.begin(now: epoch.addingTimeInterval(second))
        #expect(began == expected)
    }
}

@Test func spriteAPIRequestCarriesTokenLimit() throws {
    let request = try OpenAICompatibleClient(baseURL: URL(string: "https://example.test")!, model: "fixture")
        .makeRequest(system: nil, prompt: "fixture", schema: GenerationPrompts.spriteMarksSchema, maxTokens: SpriteGenerator.maxTokens)
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    #expect(body["max_tokens"] as? Int == 320)
}
