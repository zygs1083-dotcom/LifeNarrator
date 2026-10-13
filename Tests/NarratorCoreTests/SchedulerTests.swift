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
@Test func schedulerPersonTopicEdges() {
    var scheduler = Scheduler()
    let candidates = [Candidate(rule: rule("person", kind: .person, match: Match(aliases: ["张三"], region: .header))), Candidate(rule: rule("topic")), Candidate(rule: rule("app", kind: .app, match: Match(appNames: ["app"])))]
    #expect(scheduler.triggers(from: candidates).count == 3)
    #expect(scheduler.triggers(from: candidates).map { $0.rule.id } == ["app"])
    #expect(scheduler.triggers(from: []).isEmpty)
    #expect(scheduler.triggers(from: candidates).count == 3)
    scheduler.clearPresence()
    #expect(scheduler.triggers(from: candidates).count == 3)
}
@Test func schedulerFreeCommentsCooldown() {
    var scheduler = Scheduler()
    scheduler.recordShown(ruleID: nil, now: epoch)
    #expect(!scheduler.canShow(ruleID: nil, now: epoch.addingTimeInterval(599)))
    #expect(scheduler.canShow(ruleID: nil, now: epoch.addingTimeInterval(600)))
    #expect(scheduler.canShow(ruleID: "a", now: epoch.addingTimeInterval(5)))
}
