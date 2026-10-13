import Foundation

public struct SpriteMemory: Sendable {
    public struct Key: Hashable, Sendable {
        public let bundleId: String
        public let text: String

        public init(bundleId: String, text: String) {
            self.bundleId = bundleId
            self.text = normalized(text)
        }
    }

    public struct Status: Sendable {
        public let quip: Quip
        public let lineHint: Int
        public let lastMarkedAt: Date?
        public let cachedAt: Date?
        public let isMarked: Bool
        public let isCached: Bool
    }

    public struct ScreenStatus: Sendable {
        public var requests: Int
        public var lastRequestAt: Date
    }

    private struct Entry: Sendable {
        var quip: Quip
        var lineHint: Int
        var lastMarkedAt: Date?
        var cachedAt: Date?
    }

    public var level: Liveliness
    private var marks: [Key: Entry] = [:]
    private var recentMarks: [Key] = []
    private var screens: [UInt64: ScreenStatus] = [:]
    private var recentScreens: [UInt64] = []

    public init(level: Liveliness = .lively) { self.level = level }

    private var ttl: TimeInterval {
        switch level {
        case .quiet: 0
        case .lively: 1800
        case .rowdy: 900
        }
    }

    public func status(key: Key, now: Date) -> Status? {
        guard let entry = marks[key] else { return nil }
        return Status(quip: entry.quip, lineHint: entry.lineHint, lastMarkedAt: entry.lastMarkedAt, cachedAt: entry.cachedAt,
                      isMarked: entry.lastMarkedAt.map { now.timeIntervalSince($0) < ttl } == true,
                      isCached: entry.cachedAt.map { now.timeIntervalSince($0) < 1800 } == true)
    }

    @discardableResult
    public mutating func mark(key: Key, quip: Quip, lineHint: Int = -1, now: Date) -> Key? {
        marks[key] = Entry(quip: quip, lineHint: lineHint, lastMarkedAt: now, cachedAt: marks[key]?.cachedAt)
        return touch(key)
    }

    @discardableResult
    public mutating func cache(key: Key, quip: Quip, lineHint: Int, now: Date) -> Key? {
        marks[key] = Entry(quip: quip, lineHint: lineHint, lastMarkedAt: marks[key]?.lastMarkedAt, cachedAt: now)
        return touch(key)
    }

    public func keys(bundleId: String) -> [Key] {
        recentMarks.filter { $0.bundleId == bundleId }
    }

    public func shownQuotes(bundleId: String, now: Date) -> [String] {
        marks.filter { $0.key.bundleId == bundleId && status(key: $0.key, now: now)!.isMarked }
            .sorted { $0.value.lastMarkedAt! > $1.value.lastMarkedAt! }
            .prefix(12).map { $0.key.text }
    }

    public func screenStatus(key: UInt64) -> ScreenStatus? { screens[key] }

    @discardableResult
    public mutating func recordRequest(key: UInt64, now: Date) -> UInt64? {
        screens[key] = ScreenStatus(requests: (screens[key]?.requests ?? 0) + 1, lastRequestAt: now)
        recentScreens.removeAll { $0 == key }
        recentScreens.append(key)
        guard recentScreens.count > 200 else { return nil }
        let evicted = recentScreens.removeFirst()
        screens.removeValue(forKey: evicted)
        return evicted
    }

    private mutating func touch(_ key: Key) -> Key? {
        recentMarks.removeAll { $0 == key }
        recentMarks.append(key)
        guard recentMarks.count > 500 else { return nil }
        let evicted = recentMarks.removeFirst()
        marks.removeValue(forKey: evicted)
        return evicted
    }
}
