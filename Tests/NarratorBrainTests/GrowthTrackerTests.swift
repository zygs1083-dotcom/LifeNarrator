import Foundation
import Testing
import NarratorCore
@testable import NarratorBrain

struct GrowthTrackerTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var start: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))! }

    @Test func experienceEventsDailyCapAndPersistence() throws {
        let directory = try memoryTestDirectory()
        defer { try! FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("growth.json")
        var tracker = try GrowthTracker(url: url, now: start, calendar: calendar)
        try tracker.open(now: start)
        try tracker.open(now: start.addingTimeInterval(1))
        #expect(tracker.state.experience == 30)
        for _ in 0..<205 { try tracker.record(.narration, now: start) }
        #expect(tracker.state.narrations == 205)
        #expect(tracker.state.narrationExperienceToday == 200)
        #expect(tracker.state.experience == 230)
        try tracker.record(.chat, now: start)
        try tracker.record(.rule, now: start)
        try tracker.record(.memory, now: start)
        try tracker.tried(.gentle)
        try tracker.tried(.gentle)
        #expect(tracker.state.experience == 265)
        #expect(tracker.state.chatMessages == 1)
        #expect(tracker.state.rulesLearned == 1)
        #expect(tracker.state.personasTried == [Persona.gentle.rawValue])
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: start)!
        try tracker.record(.narration, now: tomorrow)
        let reloaded = try GrowthTracker(url: url, now: tomorrow, calendar: calendar)
        #expect(reloaded.state.experience == 296)
        #expect(reloaded.state.narrationExperienceToday == 1)
        #expect(reloaded.state.activeDays == 2)
        #expect(reloaded.state.firstMetAt == start)
    }

    @Test func levelBoundariesTitlesAndUnlocks() throws {
        for (xp, expected) in [(159, 1), (160, 2), (359, 2), (360, 3), (999, 4), (1000, 5), (35999, 29), (36000, 30), (40000, 30)] {
            let directory = try memoryTestDirectory()
            defer { try! FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("growth.json")
            var state = GrowthState(firstMetAt: start)
            state.experience = xp - 1
            state.lastActiveDay = calendar.startOfDay(for: start)
            try JSONEncoder().encode(state).write(to: url)
            var tracker = try GrowthTracker(url: url, now: start, calendar: calendar)
            try tracker.record(.narration, now: start)
            #expect(tracker.state.level == expected)
            #expect(tracker.state.experienceToNextLevel == (expected == 30 ? 0 : 40 * (expected + 1) * (expected + 1) - xp))
            #expect(tracker.state.unlocked == Set(GrowthUnlock.allCases.filter { $0.level <= expected }))
            #expect(tracker.state.nextUnlock == GrowthUnlock.allCases.first { $0.level > expected })
            #expect(!tracker.state.title(lang: .zh).isEmpty)
            #expect(!tracker.state.title(lang: .en).isEmpty)
        }
    }

    @Test func consecutiveDaysRewardEverySevenAndResetAfterGap() throws {
        let directory = try memoryTestDirectory()
        defer { try! FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("growth.json")
        var tracker = try GrowthTracker(url: url, now: start, calendar: calendar)
        for day in 0..<14 {
            let now = calendar.date(byAdding: .day, value: day, to: start)!
            try tracker.open(now: now)
            try tracker.open(now: now)
        }
        #expect(tracker.state.activeDays == 14)
        #expect(tracker.state.consecutiveDays == 14)
        #expect(tracker.state.experience == 14 * 30 + 200)
        tracker = try GrowthTracker(url: url, now: start, calendar: calendar)
        try tracker.open(now: calendar.date(byAdding: .day, value: 15, to: start)!)
        #expect(tracker.state.consecutiveDays == 1)
        #expect(tracker.state.activeDays == 15)
        #expect(tracker.state.experience == 650)
    }

    @Test func lateNightRequiresInputAfterOneAndOnlyRecordsOncePerNight() throws {
        let directory = try memoryTestDirectory()
        defer { try! FileManager.default.removeItem(at: directory) }
        var memory = try MemoryStore(url: directory.appendingPathComponent("memory.json"))
        let url = directory.appendingPathComponent("growth.json")
        let midnight = calendar.startOfDay(for: start)
        var tracker = try GrowthTracker(url: url, now: midnight, calendar: calendar)
        let one = midnight.addingTimeInterval(3600)
        try tracker.observe(appID: "fixture", appName: "Fixture", now: one.addingTimeInterval(-1),
                            lastInputAt: one.addingTimeInterval(-1), memory: &memory, lang: .zh)
        try tracker.observe(appID: "fixture", appName: "Fixture", now: one,
                            lastInputAt: midnight, memory: &memory, lang: .zh)
        #expect(memory.memories.isEmpty)
        try tracker.observe(appID: "fixture", appName: "Fixture", now: one,
                            lastInputAt: one, memory: &memory, lang: .zh)
        #expect(memory.memories.count == 1)
        #expect(memory.memories.first?.source == .stats)
        #expect(memory.memories.first?.kind == .episode)
        tracker = try GrowthTracker(url: url, now: one, calendar: calendar)
        let two = one.addingTimeInterval(3600)
        try tracker.observe(appID: "fixture", appName: "Fixture", now: two,
                            lastInputAt: two, memory: &memory, lang: .en)
        #expect(memory.memories.count == 1)
        #expect(tracker.state.experience == 35)
    }

    @Test func appEpisodeRequiresThreeContinuousActiveHoursAcrossSameAppWindows() throws {
        let directory = try memoryTestDirectory()
        defer { try! FileManager.default.removeItem(at: directory) }
        var memory = try MemoryStore(url: directory.appendingPathComponent("memory.json"))
        var tracker = try GrowthTracker(url: directory.appendingPathComponent("growth.json"), now: start, calendar: calendar)
        for minute in 0...180 {
            let now = start.addingTimeInterval(Double(minute * 60))
            try tracker.observe(appID: "fixture", appName: "Fixture", now: now,
                                lastInputAt: now, memory: &memory, lang: .en)
            if minute < 180 { #expect(memory.memories.isEmpty) }
        }
        #expect(memory.memories.count == 1)
        #expect(memory.memories[0].text.contains("Fixture"))
        #expect(memory.memories[0].text.count <= 40)
        let later = start.addingTimeInterval(181 * 60)
        try tracker.observe(appID: "fixture", appName: "Fixture", now: later,
                            lastInputAt: later, memory: &memory, lang: .en)
        #expect(memory.memories.count == 1)

        try memory.clear()
        tracker.endSession()
        for minute in 0...200 {
            let now = start.addingTimeInterval(Double(minute * 60))
            let app = minute < 100 ? "first" : "second"
            try tracker.observe(appID: app, appName: app, now: now, lastInputAt: now, memory: &memory, lang: .zh)
        }
        #expect(memory.memories.isEmpty)
        tracker.foregroundApp("excluded-app")
        tracker.foregroundApp("second")
        let gap = start.addingTimeInterval(300 * 60)
        try tracker.observe(appID: "second", appName: "second", now: gap, lastInputAt: gap, memory: &memory, lang: .zh)
        #expect(memory.memories.isEmpty)
    }

    @Test func anniversariesArePersistedAndRelationshipHasThreeBands() throws {
        let directory = try memoryTestDirectory()
        defer { try! FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("growth.json")
        var tracker = try GrowthTracker(url: url, now: start, calendar: calendar)
        var memory = try MemoryStore(url: directory.appendingPathComponent("memory.json"))
        for days in [7, 30, 100, 365] {
            let now = calendar.date(byAdding: .day, value: days, to: start)!
            let milestones = try tracker.observe(appID: "fixture", appName: "Fixture", now: now,
                                                 lastInputAt: now, memory: &memory, lang: .zh)
            #expect(milestones.contains(.anniversary(days)))
            #expect(!GrowthMilestone.anniversary(days).text(lang: .en).isEmpty)
            #expect(!GrowthMilestone.anniversary(days).text(lang: .zh).isEmpty)
            tracker = try GrowthTracker(url: url, now: now, calendar: calendar)
            #expect(try tracker.open(now: now).isEmpty)
        }
        #expect(memory.memories.count == 4)
        #expect(tracker.state.anniversaries == [7, 30, 100, 365])
        #expect(tracker.state.anniversaryEpisodes == [7, 30, 100, 365])
        let count = memory.memories.count
        let now = calendar.date(byAdding: .day, value: 365, to: start)!
        try tracker.observe(appID: "fixture", appName: "Fixture", now: now, lastInputAt: now, memory: &memory, lang: .en)
        #expect(memory.memories.count == count)
        for (days, phrase) in [(0, "刚认识"), (2, "刚认识"), (3, "已经熟了"), (29, "已经熟了"), (30, "老朋友")] {
            let date = calendar.date(byAdding: .day, value: days, to: start)!
            #expect(tracker.state.relationship(lang: .zh, now: date, calendar: calendar).contains(phrase))
        }
    }
}
