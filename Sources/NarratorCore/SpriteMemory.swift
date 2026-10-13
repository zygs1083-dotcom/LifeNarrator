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
        public let lastMarkedAt: Date?
        public let lastQuip: Quip?
        public let cachedQuip: Quip?
        public let isMarked: Bool
        public let declined: Bool
    }

    private struct Entry: Sendable {
        var lastMarkedAt: Date?
        var lastQuip: Quip?
        var cachedQuip: Quip?
        var cachedAt: Date?
        var declinedAt: Date?
    }

    public var level: Liveliness
    private var entries: [Key: Entry] = [:]
    private var recent: [Key] = []

    public init(level: Liveliness = .lively) { self.level = level }

    private var ttl: TimeInterval {
        switch level {
        case .quiet: 0
        case .lively: 1800
        case .rowdy: 900
        }
    }

    public func status(key: Key, now: Date) -> Status? {
        guard let entry = entries[key] else { return nil }
        return Status(lastMarkedAt: entry.lastMarkedAt, lastQuip: entry.lastQuip,
                      cachedQuip: entry.cachedAt.map { now.timeIntervalSince($0) < 1800 } == true ? entry.cachedQuip : nil,
                      isMarked: entry.lastMarkedAt.map { now.timeIntervalSince($0) < ttl } == true,
                      declined: entry.declinedAt.map { now.timeIntervalSince($0) < ttl } == true)
    }

    @discardableResult
    public mutating func mark(key: Key, quip: Quip, now: Date) -> Key? {
        var entry = entries[key] ?? Entry()
        entry.lastMarkedAt = now
        entry.lastQuip = quip
        entries[key] = entry
        return touch(key)
    }

    @discardableResult
    public mutating func cache(key: Key, quip: Quip, now: Date = Date()) -> Key? {
        var entry = entries[key] ?? Entry()
        entry.cachedQuip = quip
        entry.cachedAt = now
        entry.declinedAt = nil
        entries[key] = entry
        return touch(key)
    }

    @discardableResult
    public mutating func decline(key: Key, now: Date) -> Key? {
        var entry = entries[key] ?? Entry()
        entry.declinedAt = now
        entry.cachedQuip = nil
        entry.cachedAt = nil
        entries[key] = entry
        return touch(key)
    }

    public func leastRecent(among keys: [Key], now: Date) -> Key? {
        keys.filter {
            entries[$0]?.lastMarkedAt.map { now.timeIntervalSince($0) >= 60 } == true
        }.min { entries[$0]!.lastMarkedAt! < entries[$1]!.lastMarkedAt! }
    }

    private mutating func touch(_ key: Key) -> Key? {
        recent.removeAll { $0 == key }
        recent.append(key)
        guard recent.count > 500 else { return nil }
        let evicted = recent.removeFirst()
        entries.removeValue(forKey: evicted)
        return evicted
    }
}
