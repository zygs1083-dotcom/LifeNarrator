import Foundation
import Testing
@testable import NarratorCore

@Test func schedulerRuleCooldownAndGap() {
    var scheduler = Scheduler()
    #expect(scheduler.canShow(ruleID: "a", now: epoch))
    scheduler.recordShown(ruleID: "a", now: epoch)
    #expect(!scheduler.canShow(ruleID: "b", now: epoch.addingTimeInterval(4.999)))
    #expect(scheduler.canShow(ruleID: "b", now: epoch.addingTimeInterval(5)))
    #expect(!scheduler.canShow(ruleID: "a", now: epoch.addingTimeInterval(599)))
    #expect(scheduler.canShow(ruleID: "a", now: epoch.addingTimeInterval(600)))
}
@Test func schedulerSlidingMinute() {
    var scheduler = Scheduler()
    for (index, offset) in [0.0, 5, 10].enumerated() { scheduler.recordShown(ruleID: String(index), now: epoch.addingTimeInterval(offset)) }
    #expect(!scheduler.canShow(ruleID: "next", now: epoch.addingTimeInterval(59.999)))
    #expect(scheduler.canShow(ruleID: "next", now: epoch.addingTimeInterval(60)))
    scheduler.recordShown(ruleID: "next", now: epoch.addingTimeInterval(60))
    #expect(!scheduler.canShow(ruleID: "last", now: epoch.addingTimeInterval(64)))
    #expect(scheduler.canShow(ruleID: "last", now: epoch.addingTimeInterval(65)))
}
@Test func schedulerSettingsChangeAppliesToExistingHistory() {
    var scheduler = Scheduler()
    scheduler.recordShown(ruleID: "a", now: epoch)
    #expect(!scheduler.canShow(ruleID: "a", now: epoch.addingTimeInterval(30)))
    scheduler.settings.ruleCooldown = 20
    scheduler.settings.minGap = 1
    #expect(scheduler.canShow(ruleID: "a", now: epoch.addingTimeInterval(30)))
}
@Test func schedulerFreeCommentsUseOnlyGapAndMinuteBudget() {
    var scheduler = Scheduler()
    scheduler.recordShown(ruleID: nil, now: epoch)
    #expect(!scheduler.canShow(ruleID: nil, now: epoch.addingTimeInterval(4.999)))
    #expect(scheduler.canShow(ruleID: nil, now: epoch.addingTimeInterval(5)))
}

@Test func schedulerLivelinessPresets() {
    for (level, gap, limit, cooldown) in [(Liveliness.quiet, 5.0, 3, 600.0), (.lively, 1.2, 10, 120.0), (.rowdy, 0.8, 20, 60.0)] {
        let settings = Scheduler.Settings(level: level)
        #expect(settings.minGap == gap)
        #expect(settings.globalPerMinute == limit)
        #expect(settings.ruleCooldown == cooldown)
        var scheduler = Scheduler(settings: settings)
        scheduler.recordShown(ruleID: "a", now: epoch)
        #expect(!scheduler.canShow(ruleID: nil, now: epoch.addingTimeInterval(gap - 0.001)))
        #expect(scheduler.canShow(ruleID: nil, now: epoch.addingTimeInterval(gap)))
        #expect(!scheduler.canShow(ruleID: "a", now: epoch.addingTimeInterval(cooldown - 0.001)))
        #expect(scheduler.canShow(ruleID: "a", now: epoch.addingTimeInterval(cooldown)))
        for i in 1..<limit { scheduler.recordShown(ruleID: nil, now: epoch.addingTimeInterval(Double(i) * gap)) }
        #expect(!scheduler.canShow(ruleID: nil, now: epoch.addingTimeInterval(59.999)))
        #expect(scheduler.canShow(ruleID: nil, now: epoch.addingTimeInterval(60)))
    }
}
