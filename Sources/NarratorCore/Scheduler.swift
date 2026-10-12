import Foundation

public struct Scheduler: Sendable {
    public struct Settings: Sendable {
        public var ruleCooldown: TimeInterval = 600
        public var globalPerMinute: Int = 3
        public var minGap: TimeInterval = 5
        public var maxOnScreen: Int = 3
        public var dwell: TimeInterval = 6
        public init() {}
    }
    public struct Display: Equatable, Sendable {
        public let id: UUID
        public let shownAt: Date
        public let persistent: Bool
        public let screenIndex: Int
    }
    public let settings: Settings
    public private(set) var onScreen: [Display] = []
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

    public func canShow(ruleID: String?, now: Date) -> Bool {
        if let last = recent.last, now.timeIntervalSince(last) < settings.minGap { return false }
        if recent.filter({ now.timeIntervalSince($0) < 60 }).count >= settings.globalPerMinute { return false }
        if let ruleID {
            if let last = lastByRule[ruleID], now.timeIntervalSince(last) < settings.ruleCooldown { return false }
        } else if let lastFreeComment, now.timeIntervalSince(lastFreeComment) < 600 { return false }
        return true
    }

    @discardableResult
    public mutating func recordShown(ruleID: String?, now: Date, screenIndex: Int = 0, persistent: Bool = false) -> (display: Display, retired: [UUID]) {
        recent.removeAll { now.timeIntervalSince($0) >= 60 }
        recent.append(now)
        if let ruleID { lastByRule[ruleID] = now } else { lastFreeComment = now }
        var retired = expire(now: now)
        if onScreen.filter({ $0.screenIndex == screenIndex }).count >= settings.maxOnScreen {
            let oldest = onScreen.firstIndex { $0.screenIndex == screenIndex }!
            retired.append(onScreen.remove(at: oldest).id)
        }
        let display = Display(id: UUID(), shownAt: now, persistent: persistent, screenIndex: screenIndex)
        onScreen.append(display)
        return (display, retired)
    }

    @discardableResult
    public mutating func expire(now: Date) -> [UUID] {
        let expired = onScreen.filter { !$0.persistent && now.timeIntervalSince($0.shownAt) >= settings.dwell }.map(\.id)
        onScreen.removeAll { expired.contains($0.id) }
        return expired
    }
    public mutating func dismiss(_ id: UUID) { onScreen.removeAll { $0.id == id } }
}
