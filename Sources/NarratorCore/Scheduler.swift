import Foundation

public struct Scheduler: Sendable {
    public struct Settings: Sendable {
        public var ruleCooldown: TimeInterval = 600
        public var globalPerMinute: Int = 3
        public var minGap: TimeInterval = 5
        public init() {}
        public init(level: Liveliness) {
            self.init()
            switch level {
            case .quiet: break
            case .lively: ruleCooldown = 120; globalPerMinute = 10; minGap = 1.2
            case .rowdy: ruleCooldown = 60; globalPerMinute = 20; minGap = 0.8
            }
        }
    }
    public var settings: Settings
    private var lastByRule: [String: Date] = [:]
    private var recent: [Date] = []

    public init(settings: Settings = Settings()) { self.settings = settings }

    public func canShow(ruleID: String?, now: Date) -> Bool {
        if let last = recent.last, now < last.addingTimeInterval(settings.minGap) { return false }
        if recent.filter({ now.timeIntervalSince($0) < 60 }).count >= settings.globalPerMinute { return false }
        if let ruleID {
            if let last = lastByRule[ruleID], now.timeIntervalSince(last) < settings.ruleCooldown { return false }
        }
        return true
    }

    public mutating func recordShown(ruleID: String?, now: Date) {
        recent.removeAll { now.timeIntervalSince($0) >= 60 }
        recent.append(now)
        if let ruleID { lastByRule[ruleID] = now }
    }
}
