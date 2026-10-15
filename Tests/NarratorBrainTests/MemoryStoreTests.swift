import Foundation
import Testing
import NarratorCore
@testable import NarratorBrain

struct MemoryStoreTests {
    @Test func deduplicationAndCRUDPersist() throws {
        let directory = try memoryTestDirectory()
        defer { try! FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.json")
        var store = try MemoryStore(url: url)
        let original = try #require(try store.add(kind: .fact, text: "Your manager is Alice", source: .chat))
        #expect(SaidHistory.similarity(original.text, "Your manager is Alice!") >= 0.5)
        #expect(try store.add(kind: .fact, text: "Your manager is Alice!", source: .chat) == nil)
        #expect(try store.add(kind: .fact, text: "Your manager is Alicia", source: .manual) == nil)
        try store.edit(id: original.id, kind: .preference, text: "You like jasmine tea")
        try store.pin(id: original.id, pinned: true)
        let reloaded = try MemoryStore(url: url)
        let entry = try #require(reloaded.memories.first)
        #expect(entry.id == original.id)
        #expect(entry.kind == .preference)
        #expect(entry.text == "You like jasmine tea")
        #expect(entry.pinned)
        #expect(entry.source == .chat)
        try store.delete(id: original.id)
        #expect(try MemoryStore(url: url).memories.isEmpty)
        try store.add(kind: .nickname, text: "阿王", source: .manual)
        try store.clear()
        #expect(try MemoryStore(url: url).memories.isEmpty)
    }

    @Test func relevancePrioritizesNicknameKeywordsThenRecencyAndRecordsUse() throws {
        let directory = try memoryTestDirectory()
        defer { try! FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.json")
        var store = try MemoryStore(url: url)
        let now = Date()
        let relevant = try #require(try store.add(kind: .preference, text: "你讨厌开会", source: .chat, now: now))
        let nickname = try #require(try store.add(kind: .nickname, text: "叫你阿王", source: .manual, now: now))
        let old = try #require(try store.add(kind: .fact, text: "Lives in Paris", source: .chat, now: now))
        let recent = try #require(try store.add(kind: .episode, text: "凌晨三点仍在输入", source: .stats, now: now.addingTimeInterval(1)))
        let used = try store.relevant(for: "今天开会讨论 Swift", limit: 2, now: now.addingTimeInterval(2))
        #expect(used.map(\.id) == [nickname.id, relevant.id, recent.id])
        #expect(used.allSatisfy { $0.uses == 1 && $0.lastUsedAt == now.addingTimeInterval(2) })
        #expect(try MemoryStore(url: url).memories.first { $0.id == old.id }?.uses == 0)
        let english = try store.relevant(for: "PARIS itinerary", limit: 1)
        #expect(english.map(\.id) == [nickname.id, old.id])
        let ambient = try store.episodes()
        #expect(ambient.map(\.id) == [nickname.id, recent.id])
    }

    @Test func memoryBudgetKeepsWholeFactsAndOnlyCountsSelectedEntries() throws {
        let directory = try memoryTestDirectory()
        defer { try! FileManager.default.removeItem(at: directory) }
        var store = try MemoryStore(url: directory.appendingPathComponent("memory.json"))
        for word in ["春", "夏", "秋", "冬", "雨"] {
            try store.add(kind: .fact, text: String(repeating: word, count: 40), source: .manual)
        }
        let selected = try store.relevant(for: "", limit: 4)
        #expect(selected.count == 2)
        #expect(selected.allSatisfy { $0.text.count == 40 })
        #expect(store.memories.filter { $0.uses == 1 }.count == 2)
    }

    @Test func invalidTextAndCorruptedFilesExposeErrors() throws {
        let directory = try memoryTestDirectory()
        defer { try! FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.json")
        var store = try MemoryStore(url: url)
        #expect(throws: MemoryStore.Failure.self) { try store.add(kind: .fact, text: "  ", source: .manual) }
        #expect(throws: MemoryStore.Failure.self) { try store.add(kind: .fact, text: String(repeating: "字", count: 41), source: .chat) }
        try Data("broken".utf8).write(to: url)
        #expect(throws: (any Error).self) { try MemoryStore(url: url) }
    }
}

func memoryTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
