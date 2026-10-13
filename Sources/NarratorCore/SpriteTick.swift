import Foundation

public enum SpriteTick: String, Sendable {
    case snapshot, burst, idle

    public struct Attempt: Sendable {
        public var target: SpriteTarget
        public var reason: String
        public var ignoresRuleCooldown: Bool
    }

    public static func quietReason(in snapshot: ContextSnapshot, typing: Bool, moving: Bool) -> String? {
        if typing { return "typing" }
        if snapshot.secureFocused { return "secure" }
        if isSmall(snapshot) { return "small" }
        if moving { return "moving" }
        if SpriteScout.isMediaFullScreen(snapshot) { return "media" }
        return nil
    }

    private static func isSmall(_ snapshot: ContextSnapshot) -> Bool {
        snapshot.windowFrame.width < 360 || snapshot.windowFrame.height < 200
    }

    public static func attempts(in snapshot: ContextSnapshot, candidates: [Candidate], memory: SpriteMemory,
                                onScreen: [SpriteTarget], level: Liveliness, switching: Bool,
                                scheduler: Scheduler, revisitAllowed: Bool, now: Date) -> [Attempt] {
        let candidates = snapshot.textSource == .none
            ? candidates.filter { $0.rule.kind == .app || $0.rule.kind == .site } : candidates
        let all = SpriteScout.targets(in: snapshot, candidates: candidates, memory: SpriteMemory(level: level),
                                      onScreen: onScreen, level: level)
        let fresh = all.filter {
            if snapshot.textSource == .none { return true }
            let status = memory.status(key: .init(bundleId: snapshot.bundleId, text: $0.text), now: now)
            return status?.isMarked != true && ($0.category == .rule || status?.declined != true)
        }
        var attempts = fresh.map { Attempt(target: $0, reason: "fresh", ignoresRuleCooldown: false) }
        guard switching, level != .quiet else { return attempts }
        let available = all.filter {
            $0.category == .rule || memory.status(key: .init(bundleId: snapshot.bundleId, text: $0.text), now: now)?.declined != true
        }
        if snapshot.textSource != .none && !available.isEmpty && available.allSatisfy({
            memory.status(key: .init(bundleId: snapshot.bundleId, text: $0.text), now: now)?.isMarked == true
                || ($0.candidate != nil && scheduler.canShow(ruleID: nil, now: now)
                    && !scheduler.canShow(ruleID: $0.candidate!.rule.id, now: now))
        }) {
            var remaining = available
            while let key = memory.leastRecent(among: remaining.map { .init(bundleId: snapshot.bundleId, text: $0.text) }, now: now) {
                let index = remaining.firstIndex { normalized($0.text) == key.text }!
                attempts.append(Attempt(target: remaining.remove(at: index), reason: "least-recent", ignoresRuleCooldown: true))
            }
        }
        if revisitAllowed {
            let title = snapshot.windowTitle ?? snapshot.appName
            let index = snapshot.textLines.firstIndex { normalized($0.text) == normalized(title) }
            let text = index.map { snapshot.textLines[$0].text } ?? title
            attempts.append(Attempt(target: SpriteTarget(category: .revisit, lineIndex: index ?? -1,
                range: text.startIndex..<text.endIndex, text: text, score: 0), reason: "revisit", ignoresRuleCooldown: true))
        }
        return attempts
    }

    public static func burstDelays(level: Liveliness) -> [TimeInterval] {
        switch level {
        case .quiet: []
        case .lively: [1.5]
        case .rowdy: [1, 2]
        }
    }

    public static func idleDelay<R: RandomNumberGenerator>(level: Liveliness, using random: inout R) -> TimeInterval? {
        switch level {
        case .quiet: nil
        case .lively: Double.random(in: 5...11, using: &random)
        case .rowdy: Double.random(in: 2.5...5.5, using: &random)
        }
    }

    public static func screenLimit(level: Liveliness) -> Int {
        switch level {
        case .quiet: 0
        case .lively: 6
        case .rowdy: 12
        }
    }
}

public struct SpriteModelBudget: Sendable {
    private var requests: [Date] = []
    public init() {}

    @discardableResult
    public mutating func begin(now: Date) -> Bool {
        requests.removeAll { now.timeIntervalSince($0) >= 60 }
        guard requests.count < 4 else { return false }
        requests.append(now)
        return true
    }
}
