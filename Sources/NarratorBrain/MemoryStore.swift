import Foundation
import NarratorCore

public struct Memory: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable { case fact, preference, nickname, episode }
    public enum Source: String, Codable, Sendable { case chat, stats, manual }
    public let id: UUID
    public var kind: Kind
    public var text: String
    public let source: Source
    public let createdAt: Date
    public var lastUsedAt: Date
    public var uses: Int
    public var pinned: Bool
}

public struct MemoryStore: Sendable {
    public enum Failure: Error { case invalidText }
    private let url: URL
    public private(set) var memories: [Memory]

    public init(url: URL) throws {
        self.url = url
        memories = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode([Memory].self, from: Data(contentsOf: url)) : []
    }

    @discardableResult
    public mutating func add(kind: Memory.Kind, text: String, source: Memory.Source, now: Date = Date()) throws -> Memory? {
        let text = try Self.validated(text)
        guard !memories.contains(where: { SaidHistory.similarity($0.text, text) >= 0.5 }) else { return nil }
        let entry = Memory(id: UUID(), kind: kind, text: text, source: source, createdAt: now,
                           lastUsedAt: now, uses: 0, pinned: false)
        memories.append(entry)
        try save()
        return entry
    }

    public mutating func edit(id: UUID, kind: Memory.Kind, text: String) throws {
        let text = try Self.validated(text)
        let index = memories.firstIndex { $0.id == id }!
        memories[index].kind = kind
        memories[index].text = text
        try save()
    }

    public mutating func pin(id: UUID, pinned: Bool) throws {
        memories[memories.firstIndex { $0.id == id }!].pinned = pinned
        try save()
    }

    public mutating func delete(id: UUID) throws {
        memories.removeAll { $0.id == id }
        try save()
    }

    public mutating func clear() throws {
        memories = []
        try save()
    }

    /// The limit counts memories in addition to the most recent nickname.
    public mutating func relevant(for screenText: String, limit: Int, now: Date = Date()) throws -> [Memory] {
        let keywords = Self.keywords(screenText)
        let candidates = memories.filter { $0.kind != .nickname }.sorted {
            let left = Self.keywords($0.text).intersection(keywords).count
            let right = Self.keywords($1.text).intersection(keywords).count
            if left != right { return left > right }
            if $0.lastUsedAt != $1.lastUsedAt { return $0.lastUsedAt > $1.lastUsedAt }
            return $0.createdAt > $1.createdAt
        }
        let nickname = memories.filter { $0.kind == .nickname }.max { $0.createdAt < $1.createdAt }
        return try use((nickname.map { [$0] } ?? []) + candidates.prefix(limit), now: now)
    }

    public mutating func episodes(limit: Int = 2, now: Date = Date()) throws -> [Memory] {
        let nickname = memories.filter { $0.kind == .nickname }.max { $0.createdAt < $1.createdAt }
        let episodes = memories.filter { $0.kind == .episode }.sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(limit)
        return try use((nickname.map { [$0] } ?? []) + episodes, now: now)
    }

    public mutating func chat(now: Date = Date()) throws -> [Memory] {
        let selected = memories.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.lastUsedAt != $1.lastUsedAt { return $0.lastUsedAt > $1.lastUsedAt }
            return $0.createdAt > $1.createdAt
        }.prefix(20)
        for entry in selected {
            let index = memories.firstIndex { $0.id == entry.id }!
            memories[index].lastUsedAt = now
            memories[index].uses += 1
        }
        if !selected.isEmpty { try save() }
        return Array(selected)
    }

    private mutating func use(_ candidates: [Memory], now: Date) throws -> [Memory] {
        var tokens = 0.0
        let selected = candidates.filter { entry in
            let cost = SpritePrompt.estimatedTokens(entry.text) + 2
            guard tokens + cost <= 80 else { return false }
            tokens += cost
            return true
        }
        for entry in selected {
            let index = memories.firstIndex { $0.id == entry.id }!
            memories[index].lastUsedAt = now
            memories[index].uses += 1
        }
        if !selected.isEmpty { try save() }
        return selected.map { entry in memories.first { $0.id == entry.id }! }
    }

    private static func validated(_ text: String) throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 40 else { throw Failure.invalidText }
        return text
    }

    private static func keywords(_ text: String) -> Set<String> {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        return Set(words.flatMap { word -> [String] in
            let characters = Array(word)
            if word.unicodeScalars.contains(where: { $0.value >= 0x2E80 && $0.value <= 0x9FFF }), characters.count >= 2 {
                return (0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) }
            }
            return word.count >= 3 ? [String(word)] : []
        })
    }

    private func save() throws {
        try JSONEncoder().encode(memories).write(to: url, options: .atomic)
    }
}
