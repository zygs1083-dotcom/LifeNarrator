import Foundation

public struct Scheduler: Sendable {
    public struct Settings: Sendable {
        public var ruleCooldown: TimeInterval = 600
        public var globalPerMinute: Int = 3
        public var minGap: TimeInterval = 5
        public init() {}
    }
    public var settings: Settings
    private var lastByRule: [String: Date] = [:]
    private var recent: [Date] = []
    private var lastFreeComment: Date?
    private var present: Set<String> = []

    public init(settings: Settings = Settings()) { self.settings = settings }

    public mutating func triggers(from candidates: [Candidate]) -> [Candidate] {
        let edgeCandidates = candidates.filter { $0.rule.kind == .person || $0.rule.kind == .topic }
        let incoming = Set(edgeCandidates.map { $0.rule.id })
        let triggers = candidates.filter { !incoming.contains($0.rule.id) || !present.contains($0.rule.id) }
        present = incoming
        return triggers
    }

    /// Focus left the window, so whatever is on it counts as new when the user comes back.
    public mutating func clearPresence() { present = [] }

    public func canShow(ruleID: String?, now: Date) -> Bool {
        if let last = recent.last, now.timeIntervalSince(last) < settings.minGap { return false }
        if recent.filter({ now.timeIntervalSince($0) < 60 }).count >= settings.globalPerMinute { return false }
        if let ruleID {
            if let last = lastByRule[ruleID], now.timeIntervalSince(last) < settings.ruleCooldown { return false }
        } else if let lastFreeComment, now.timeIntervalSince(lastFreeComment) < 600 { return false }
        return true
    }

    public mutating func recordShown(ruleID: String?, now: Date) {
        recent.removeAll { now.timeIntervalSince($0) >= 60 }
        recent.append(now)
        if let ruleID { lastByRule[ruleID] = now } else { lastFreeComment = now }
    }
}
