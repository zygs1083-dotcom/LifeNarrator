import Foundation

public enum SpriteTick: String, Sendable {
    case snapshot, mark, followup

    public struct Attempt: Sendable {
        public var target: SpriteTarget?
        public var mark: SpriteMark?
        public var reason: String
        public var ignoresRuleCooldown: Bool
    }

    public static func resetsWindow(appChanged: Bool, windowChanged: Bool) -> Bool {
        appChanged || windowChanged
    }

    public static func revisitAllowed(lastVisit: Date?, lastRevisit: Date?, now: Date) -> Bool {
        lastVisit.map { now.timeIntervalSince($0) < 120 } == true
            && lastRevisit.map { now.timeIntervalSince($0) < 600 } != true
    }

    public static func quietReason(in snapshot: ContextSnapshot, typing: Bool, moving: Bool) -> String? {
        if typing { return "typing" }
        if snapshot.secureFocused { return "secure" }
        if snapshot.windowFrame.width < 360 || snapshot.windowFrame.height < 200 { return "small" }
        if moving { return "moving" }
        if SpriteScout.isMediaFullScreen(snapshot) { return "media" }
        return nil
    }

    public static func attempts(in snapshot: ContextSnapshot, candidates: [Candidate], memory: SpriteMemory,
                                level: Liveliness, switching: Bool, scheduler: Scheduler, revisitAllowed: Bool,
                                screen: SpriteScreen, screenKey: UInt64, hasModel: Bool, requestAllowed: Bool,
                                now: Date) -> [Attempt] {
        let candidates = snapshot.textSource == .none
            ? candidates.filter { $0.rule.kind == .app || $0.rule.kind == .site } : candidates
        let all = SpriteScout.targets(in: snapshot, candidates: candidates, memory: SpriteMemory(level: level),
                                      level: level)
        var attempts = all.filter {
            $0.category == .rule && scheduler.canShow(ruleID: $0.candidate!.rule.id, now: now)
                && memory.status(key: .init(bundleId: snapshot.bundleId, text: $0.text), now: now)?.isMarked != true
        }.map { Attempt(target: $0, reason: "rule", ignoresRuleCooldown: false) }
        guard level != .quiet else { return attempts }
        if !hasModel {
            attempts += all.filter {
                $0.category != .rule && memory.status(key: .init(bundleId: snapshot.bundleId, text: $0.text), now: now)?.isMarked != true
            }.map { Attempt(target: $0, reason: "local", ignoresRuleCooldown: false) }
            if attempts.contains(where: { $0.reason == "local" }) { return attempts }
        }
        let lines = screen.lines.map { snapshot.textLines[$0.lineIndex] }
        let located = memory.keys(bundleId: snapshot.bundleId).compactMap { key -> (key: SpriteMemory.Key, mark: SpriteMark, status: SpriteMemory.Status)? in
            let status = memory.status(key: key, now: now)!
            let hint = screen.lines.firstIndex { $0.lineIndex == status.lineHint } ?? -1
            guard let hit = SpriteLocator.locate(quote: key.text, lineHint: hint, in: lines) else { return nil }
            let index = screen.lines[hit.lineIndex].lineIndex
            guard FoldedLine(screen.lines[hit.lineIndex].text).text.range(of: key.text) != nil,
                  !SpritePrompt.privacyRanges(in: snapshot.textLines[index].text).contains(where: { $0.overlaps(hit.range) }) else { return nil }
            return (key, SpriteMark(lineIndex: index, range: hit.range,
                                    quote: String(snapshot.textLines[index].text[hit.range]), quip: status.quip), status)
        }
        if hasModel {
            let replay = located.filter { $0.status.isCached && !$0.status.isMarked }.map {
                Attempt(mark: $0.mark, reason: "cache", ignoresRuleCooldown: true)
            }
            if !replay.isEmpty { return attempts + replay }
            if !screen.lines.isEmpty && requestAllowed && (memory.screenStatus(key: screenKey)?.requests ?? 0) < requestsPerScreen(level: level) {
                return attempts + [Attempt(reason: "request", ignoresRuleCooldown: false)]
            }
        }
        guard switching else { return attempts }
        if revisitAllowed {
            let title = snapshot.windowTitle ?? snapshot.appName
            let index = snapshot.textLines.firstIndex { normalized($0.text) == normalized(title) }
            let text = index.map { snapshot.textLines[$0].text } ?? title
            guard memory.status(key: .init(bundleId: snapshot.bundleId, text: text), now: now)?.isMarked != true else { return attempts }
            attempts.append(Attempt(target: SpriteTarget(category: .revisit, lineIndex: index ?? -1,
                range: text.startIndex..<text.endIndex, text: text, score: 0), reason: "revisit", ignoresRuleCooldown: true))
        }
        return attempts
    }

    public static func followupDelay(level: Liveliness) -> TimeInterval {
        switch level { case .quiet: 0; case .lively: 20; case .rowdy: 10 }
    }

    public static func requestsPerScreen(level: Liveliness) -> Int {
        switch level { case .quiet: 0; case .lively: 2; case .rowdy: 3 }
    }

    public static func windowRequestInterval(level: Liveliness) -> TimeInterval {
        switch level { case .quiet: 0; case .lively: 8; case .rowdy: 5 }
    }

    public static func localBurst(level: Liveliness) -> [TimeInterval] {
        switch level { case .quiet: []; case .lively: [3]; case .rowdy: [1.5, 3] }
    }

    public static func screenLimit(level: Liveliness) -> Int {
        switch level { case .quiet: 0; case .lively: 8; case .rowdy: 14 }
    }
}

public struct SpriteModelBudget: Sendable {
    private var requests: [Date] = []
    private let perMinute: Int
    public init(perMinute: Int) { self.perMinute = perMinute }

    @discardableResult
    public mutating func begin(now: Date) -> Bool {
        requests.removeAll { now.timeIntervalSince($0) >= 60 }
        guard requests.count < perMinute else { return false }
        requests.append(now)
        return true
    }
}
