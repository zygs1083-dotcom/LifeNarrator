import Foundation
import Testing
@testable import NarratorCore

@Test func rowdyPrefetchRequiresSuccessfulLocatedBatchRoomScreenAllowanceAndBudget() {
    func allowed(level: Liveliness = .rowdy, succeeded: Bool = true, located: Int = 1,
                 queued: Int = 2, requests: Int = 7, budget: Bool = true) -> Bool {
        SpriteTick.prefetchAllowed(level: level, succeeded: succeeded, located: located,
            queued: queued, requests: requests, budgetAllowed: budget)
    }
    #expect(allowed())
    #expect(allowed(queued: 0))
    #expect(!allowed(level: .quiet))
    #expect(!allowed(level: .lively))
    #expect(!allowed(succeeded: false))
    #expect(!allowed(located: 0))
    #expect(!allowed(queued: 3))
    #expect(!allowed(requests: 8))
    #expect(!allowed(budget: false))
}

@Test func cadenceModelBudgetsFollowLevelsAndRenewAfterOneMinute() {
    for (level, limit) in [(Liveliness.quiet, 0), (.lively, 6), (.rowdy, 15)] {
        var budget = SpriteModelBudget(level: level)
        for _ in 0..<limit { let began = budget.begin(now: epoch); #expect(began) }
        #expect(!budget.allows(now: epoch.addingTimeInterval(59.999)))
        let denied = budget.begin(now: epoch.addingTimeInterval(59.999))
        #expect(!denied)
        #expect(budget.allows(now: epoch.addingTimeInterval(60)) == (limit > 0))
    }
}

@Test func requestExcludesEveryShownQuoteAndQueuedOriginals() {
    var memory = SpriteMemory(level: .rowdy)
    for i in 0..<20 {
        memory.mark(key: .init(bundleId: "app", text: "shown \(i)"), quip: quip("line"), now: epoch)
    }
    memory.mark(key: .init(bundleId: "other", text: "other app"), quip: quip("line"), now: epoch)
    memory.cache(key: .init(bundleId: "app", text: "unqueued cache"), quip: quip("line"), lineHint: 0, now: epoch)
    let excluded = memory.requestQuotes(bundleId: "app", queued: [" Queued Original ", "SHOWN 0"], now: epoch)
    #expect(excluded.count == 21)
    #expect(excluded.contains("shown 0"))
    #expect(excluded.contains("shown 19"))
    #expect(excluded.contains("queued original"))
    #expect(!excluded.contains("other app"))
    #expect(!excluded.contains("unqueued cache"))
    #expect(memory.requestQuotes(bundleId: "app", queued: ["queued"], now: epoch.addingTimeInterval(900)) == ["queued"])
}

@Test func ambientTriggerRequiresDwellSilenceExhaustionNoTypingAndModel() {
    func allowed(level: Liveliness = .rowdy, dwell: Double = 8, silence: Double = 10,
                 exhausted: Bool = true, typing: Bool = false, hasModel: Bool = true) -> Bool {
        SpriteTick.ambientAllowed(level: level, dwell: dwell, sinceLast: silence,
            exhausted: exhausted, typing: typing, hasModel: hasModel)
    }
    #expect(allowed())
    #expect(!allowed(level: .quiet, silence: 60))
    #expect(!allowed(level: .lively, silence: 29.999))
    #expect(allowed(level: .lively, silence: 30))
    #expect(!allowed(dwell: 7.999))
    #expect(!allowed(silence: 9.999))
    #expect(!allowed(exhausted: false))
    #expect(!allowed(typing: true))
    #expect(!allowed(hasModel: false))
}

@Test func openerRequiresRowdyAppOrSiteAndTenMinuteRuleCooldown() {
    for kind in [RuleKind.app, .site] {
        #expect(SpriteTick.openerAllowed(level: .rowdy, kind: kind, last: nil, now: epoch))
        #expect(!SpriteTick.openerAllowed(level: .rowdy, kind: kind, last: epoch, now: epoch.addingTimeInterval(599.999)))
        #expect(SpriteTick.openerAllowed(level: .rowdy, kind: kind, last: epoch, now: epoch.addingTimeInterval(600)))
        for level in [Liveliness.quiet, .lively] {
            #expect(!SpriteTick.openerAllowed(level: level, kind: kind, last: nil, now: epoch))
        }
    }
    for kind in [RuleKind.person, .topic, .time] {
        #expect(!SpriteTick.openerAllowed(level: .rowdy, kind: kind, last: nil, now: epoch))
    }
}

@Test func openerCanSkipGapButStillHonorsMinuteBudget() {
    var scheduler = Scheduler(settings: .init(level: .rowdy))
    scheduler.recordShown(ruleID: nil, now: epoch)
    #expect(!scheduler.canShow(ruleID: nil, now: epoch.addingTimeInterval(0.1)))
    #expect(scheduler.canShow(ruleID: nil, now: epoch.addingTimeInterval(0.1), ignoringGap: true))
    for _ in 1..<30 { scheduler.recordShown(ruleID: nil, now: epoch) }
    #expect(!scheduler.canShow(ruleID: nil, now: epoch.addingTimeInterval(0.1), ignoringGap: true))
}

@Test func everyRowdyRequestAsksForFiveSpecificSpotsInUserPrompt() {
    for lang in Lang.allCases {
        let k = SpriteTick.requestCount(level: .rowdy, maxOnScreen: 1)
        let prompt = GenerationPrompts.spriteMarks(app: "Fixture", title: "Window",
            screen: .init(lines: [(0, "test text")], tokens: 2), exclude: ["queued text"],
            persona: .sharp, lang: lang, k: k)
        #expect(prompt.user.contains(lang == .zh ? "挑满 5 处，每处都要说到具体内容" : "pick close to 5 spots, each with a specific point"))
        #expect(prompt.user.contains("queued text"))
        #expect(!prompt.system.contains("queued text"))
    }
}

@Test func minuteStatsCountSourcesRepeatsCancellationsAndBusyAcrossBoundary() {
    var stats = SpriteMinuteStats(now: epoch)
    for source in ["model", "cache", "ambient", "opener", "rule", "local"] {
        stats.record(source: source, shown: true, repeatRejected: false)
    }
    stats.record(source: "model", shown: false, repeatRejected: true)
    stats.begin(now: epoch.addingTimeInterval(10))
    stats.end(now: epoch.addingTimeInterval(20), wasCancelled: true)
    stats.begin(now: epoch.addingTimeInterval(40))
    #expect(stats.line(now: epoch.addingTimeInterval(60)) == "[sprite] minute shows=6 model=1 cache=1 ambient=1 opener=1 rule=2 repeats=1 requests=2 cancelled=1 busy=50%")
    stats.end(now: epoch.addingTimeInterval(90), wasCancelled: false)
    #expect(stats.line(now: epoch.addingTimeInterval(120)) == "[sprite] minute shows=0 model=0 cache=0 ambient=0 opener=0 rule=0 repeats=0 requests=0 cancelled=0 busy=50%")
}
