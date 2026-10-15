import Foundation
import NarratorCore

public enum GrowthUnlock: String, Codable, Sendable, CaseIterable {
    case spriteName, emoji, starBubble, catchphrase, greetings, starryTheme, oldFriend

    public var level: Int {
        switch self {
        case .spriteName: 2
        case .emoji: 3
        case .starBubble: 5
        case .catchphrase: 8
        case .greetings: 10
        case .starryTheme: 15
        case .oldFriend: 20
        }
    }

    public func name(lang: Lang) -> String {
        switch self {
        case .spriteName: lang == .zh ? "给小精灵起名字" : "a name for your sprite"
        case .emoji: lang == .zh ? "更多表情" : "more emoji"
        case .starBubble: lang == .zh ? "星星气泡" : "star bubbles"
        case .catchphrase: lang == .zh ? "口头禅" : "a catchphrase"
        case .greetings: lang == .zh ? "早安、晚安和纪念日旁白" : "greetings and anniversary asides"
        case .starryTheme: lang == .zh ? "星空配色" : "the starry theme"
        case .oldFriend: lang == .zh ? "老朋友人格" : "the old friend persona"
        }
    }
}

public struct GrowthState: Codable, Sendable {
    public let firstMetAt: Date
    public var activeDays = 0
    public var consecutiveDays = 0
    public var narrations = 0
    public var chatMessages = 0
    public var rulesLearned = 0
    public var personasTried: Set<String> = []
    public var experience = 0
    public var level = 1
    public var unlocked: Set<GrowthUnlock> = []
    public var lastActiveDay: Date?
    public var narrationExperienceToday = 0
    public var lastLateNight: Date?
    public var anniversaries: Set<Int> = []
    public var anniversaryEpisodes: Set<Int> = []

    public var nextLevelExperience: Int? { level < 30 ? 40 * (level + 1) * (level + 1) : nil }
    public var experienceToNextLevel: Int { nextLevelExperience.map { $0 - experience } ?? 0 }
    public var nextUnlock: GrowthUnlock? { GrowthUnlock.allCases.first { $0.level > level } }

    public func title(lang: Lang) -> String {
        let index = (level - 1) / 5
        return lang == .zh
            ? ["刚孵出来", "小跟班", "吐槽学徒", "碎嘴子", "老搭档", "灵魂伙伴"][index]
            : ["Newly hatched", "Little sidekick", "Quip apprentice", "Chatterbox", "Longtime companion", "Soulmate"][index]
    }

    public func daysKnown(now: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: firstMetAt),
                                to: calendar.startOfDay(for: now)).day!
    }

    public func relationship(lang: Lang, now: Date, calendar: Calendar = .current) -> String {
        let days = daysKnown(now: now, calendar: calendar)
        if days < 3 { return lang == .zh ? "刚认识，客气一点" : "You just met; be polite." }
        if days < 30 { return lang == .zh ? "已经熟了" : "You know each other well." }
        return lang == .zh ? "老朋友，可以开熟人玩笑、提起以前的事" : "Old friends; you can tease gently and recall shared memories."
    }
}

public enum GrowthMilestone: Sendable, Equatable {
    case level(Int)
    case anniversary(Int)

    public func text(lang: Lang) -> String {
        switch self {
        case .level(let level):
            let unlock = GrowthUnlock.allCases.first { $0.level == level }
            if lang == .zh { return "升级啦！Lv.\(level)" + (unlock.map { "，解锁了\($0.name(lang: lang))" } ?? "，又长大一点啦") }
            return "Level up! Lv.\(level)" + (unlock.map { ", unlocked \($0.name(lang: lang))" } ?? ", growing together!")
        case .anniversary(let days):
            return lang == .zh ? "认识 \(days) 天啦，谢谢你一直在" : "We've known each other for \(days) days. Thanks for being here!"
        }
    }
}

public struct GrowthTracker: Sendable {
    public enum Event: Sendable { case narration, chat, rule, memory }
    private let url: URL
    private let calendar: Calendar
    public private(set) var state: GrowthState
    private var sessionApp: String?
    private var sessionStarted: Date?
    private var lastObservedAt: Date?
    private var sessionRecorded = false

    public init(url: URL, now: Date = Date(), calendar: Calendar = .current) throws {
        self.url = url
        self.calendar = calendar
        state = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(GrowthState.self, from: Data(contentsOf: url)) : GrowthState(firstMetAt: now)
    }

    @discardableResult
    public mutating func open(now: Date = Date()) throws -> [GrowthMilestone] {
        let oldLevel = state.level
        let changed = activateDay(now: now)
        let anniversaries = [7, 30, 100, 365].filter {
            $0 <= state.daysKnown(now: now, calendar: calendar) && !state.anniversaries.contains($0)
        }
        state.anniversaries.formUnion(anniversaries)
        updateLevel()
        if changed || !anniversaries.isEmpty { try save() }
        return levels(after: oldLevel) + anniversaries.map { .anniversary($0) }
    }

    @discardableResult
    public mutating func record(_ event: Event, now: Date = Date()) throws -> [GrowthMilestone] {
        let milestones = try open(now: now)
        let oldLevel = state.level
        switch event {
        case .narration:
            state.narrations += 1
            if state.narrationExperienceToday < 200 {
                state.narrationExperienceToday += 1
                state.experience += 1
            }
        case .chat: state.chatMessages += 1; state.experience += 10
        case .rule: state.rulesLearned += 1; state.experience += 20
        case .memory: state.experience += 5
        }
        updateLevel()
        try save()
        return milestones + levels(after: oldLevel)
    }

    public mutating func tried(_ persona: Persona) throws {
        if state.personasTried.insert(persona.rawValue).inserted { try save() }
    }

    /// Only application identity and input times enter this path; screen text has no parameter.
    @discardableResult
    public mutating func observe(appID: String, appName: String, now: Date, lastInputAt: Date,
                                 memory: inout MemoryStore, lang: Lang) throws -> [GrowthMilestone] {
        var milestones = try open(now: now)
        for days in state.anniversaries.subtracting(state.anniversaryEpisodes).sorted() {
            let date = dateString(calendar.date(byAdding: .day, value: days, to: state.firstMetAt)!)
            let text = lang == .zh ? "\(date)，认识满 \(days) 天" : "\(date): \(days) days together"
            if try memory.add(kind: .episode, text: text, source: .stats, now: now) != nil {
                milestones += try record(.memory, now: now)
            }
            state.anniversaryEpisodes.insert(days)
            try save()
        }
        let day = calendar.startOfDay(for: now)
        let hour = calendar.component(.hour, from: now)
        if (1..<6).contains(hour), lastInputAt >= day.addingTimeInterval(3600),
           now.timeIntervalSince(lastInputAt) < 60, state.lastLateNight != day {
            let text = lang == .zh ? "\(dateString(now)) 凌晨 \(hour) 点仍有输入" : "\(dateString(now)): input at \(hour) AM"
            if try memory.add(kind: .episode, text: text, source: .stats, now: now) != nil {
                milestones += try record(.memory, now: now)
            }
            state.lastLateNight = day
            try save()
        }
        let active = now.timeIntervalSince(lastInputAt) < 60
        if !active || sessionApp != appID || lastObservedAt.map({ now.timeIntervalSince($0) > 90 }) == true {
            sessionApp = appID
            sessionStarted = active ? now : nil
            sessionRecorded = false
        }
        if active && sessionStarted == nil { sessionStarted = now }
        lastObservedAt = now
        if let sessionStarted, now.timeIntervalSince(sessionStarted) >= 3 * 3600, !sessionRecorded {
            let prefix = dateString(now)
            let app = String(appName.prefix(16))
            let text = lang == .zh ? "\(prefix)，连续使用 \(app) 3 小时" : "\(prefix): \(app) for 3 hours"
            if try memory.add(kind: .episode, text: text, source: .stats, now: now) != nil {
                milestones += try record(.memory, now: now)
            }
            sessionRecorded = true
        }
        return milestones
    }

    mutating func foregroundApp(_ appID: String) {
        if sessionApp != appID { endSession() }
    }

    public mutating func endSession() {
        sessionApp = nil
        sessionStarted = nil
        lastObservedAt = nil
        sessionRecorded = false
    }

    private mutating func activateDay(now: Date) -> Bool {
        let day = calendar.startOfDay(for: now)
        guard state.lastActiveDay != day else { return false }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: day)!
        state.consecutiveDays = state.lastActiveDay == yesterday ? state.consecutiveDays + 1 : 1
        state.activeDays += 1
        state.lastActiveDay = day
        state.narrationExperienceToday = 0
        state.experience += 30
        if state.consecutiveDays.isMultiple(of: 7) { state.experience += 100 }
        return true
    }

    private mutating func updateLevel() {
        state.level = min(30, max(1, Int(Double(state.experience / 40).squareRoot())))
        state.unlocked = Set(GrowthUnlock.allCases.filter { $0.level <= state.level })
    }

    private func levels(after oldLevel: Int) -> [GrowthMilestone] {
        state.level > oldLevel ? ((oldLevel + 1)...state.level).map { .level($0) } : []
    }

    private func dateString(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private func save() throws {
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
}
