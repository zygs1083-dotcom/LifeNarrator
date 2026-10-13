import Foundation
import Testing
@testable import NarratorCore

@Test func spriteMemoryTTLAndNormalizedKeys() {
    let key = SpriteMemory.Key(bundleId: "test", text: "  Ｈello   WORLD  ")
    #expect(key == SpriteMemory.Key(bundleId: "test", text: "hello world"))
    #expect(key != SpriteMemory.Key(bundleId: "other", text: "hello world"))
    for (level, ttl) in [(Liveliness.lively, 1800.0), (.rowdy, 900.0)] {
        var memory = SpriteMemory(level: level)
        #expect(memory.status(key: key, now: epoch) == nil)
        memory.mark(key: key, quip: quip("你好"), now: epoch)
        #expect(memory.status(key: key, now: epoch.addingTimeInterval(ttl - 0.001))?.isMarked == true)
        #expect(memory.status(key: key, now: epoch.addingTimeInterval(ttl))?.isMarked == false)
        #expect(memory.status(key: key, now: epoch)?.lastQuip?.text == "你好")
    }
}

@Test func spriteMemoryScoutExclusionAndDeclinedRules() {
    let line = TextLine(text: "构建失败", rect: CGRect(x: 300, y: 100, width: 180, height: 16))
    let snapshot = ContextSnapshot(bundleId: "test", appName: "test", pid: 1, windowFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                   contentFrame: CGRect(x: 0, y: 50, width: 800, height: 550), textLines: [line], textSource: .ax, capturedAt: epoch)
    let key = SpriteMemory.Key(bundleId: snapshot.bundleId, text: line.text)
    var memory = SpriteMemory()
    memory.mark(key: key, quip: quip("报错了"), now: epoch)
    #expect(SpriteScout.targets(in: snapshot, candidates: [], memory: memory, onScreen: [], level: .lively).isEmpty)
    var later = snapshot; later.capturedAt = epoch.addingTimeInterval(1800)
    #expect(!SpriteScout.targets(in: later, candidates: [], memory: memory, onScreen: [], level: .lively).isEmpty)
    memory.decline(key: key, now: later.capturedAt)
    #expect(SpriteScout.targets(in: later, candidates: [], memory: memory, onScreen: [], level: .lively).isEmpty)
    let topic = rule(match: Match(aliases: [line.text]))
    let candidate = Candidate(rule: topic, lineIndex: 0, matchRange: line.text.startIndex..<line.text.endIndex)
    #expect(SpriteScout.targets(in: later, candidates: [candidate], memory: memory, onScreen: [], level: .lively).first?.category == .rule)
    later.capturedAt = epoch.addingTimeInterval(3600)
    #expect(!SpriteScout.targets(in: later, candidates: [], memory: memory, onScreen: [], level: .lively).isEmpty)
}

@Test func spriteMemoryLeastRecentUsesTenSecondMinimum() {
    var memory = SpriteMemory()
    let keys = (0..<3).map { SpriteMemory.Key(bundleId: "test", text: String($0)) }
    memory.mark(key: keys[0], quip: quip("早"), now: epoch)
    memory.mark(key: keys[1], quip: quip("晚"), now: epoch.addingTimeInterval(5))
    #expect(memory.leastRecent(among: keys, now: epoch.addingTimeInterval(9.999)) == nil)
    #expect(memory.leastRecent(among: keys.reversed(), now: epoch.addingTimeInterval(10)) == keys[0])
    #expect(memory.leastRecent(among: [keys[1], keys[2]], now: epoch.addingTimeInterval(20)) == keys[1])
}

@Test func spriteMemoryCacheIsIndependentOfMarkTTL() {
    var memory = SpriteMemory(level: .rowdy)
    let key = SpriteMemory.Key(bundleId: "test", text: "目标")
    memory.decline(key: key, now: epoch)
    #expect(memory.status(key: key, now: epoch.addingTimeInterval(899))?.declined == true)
    #expect(memory.status(key: key, now: epoch.addingTimeInterval(900))?.declined == false)
    memory.cache(key: key, quip: quip("模型句"), now: epoch)
    #expect(memory.status(key: key, now: epoch)?.declined == false)
    memory.mark(key: key, quip: quip("模板句"), now: epoch)
    #expect(memory.status(key: key, now: epoch.addingTimeInterval(900))?.cachedQuip?.text == "模型句")
    #expect(memory.status(key: key, now: epoch.addingTimeInterval(1800))?.cachedQuip == nil)
    #expect(memory.status(key: key, now: epoch)?.lastQuip?.text == "模板句")
    memory.decline(key: key, now: epoch.addingTimeInterval(1))
    #expect(memory.status(key: key, now: epoch.addingTimeInterval(1))?.cachedQuip == nil)
}

@Test func spriteMemoryLRUEvictsBeyondFiveHundred() {
    var memory = SpriteMemory()
    let keys = (0...500).map { SpriteMemory.Key(bundleId: "test", text: String($0)) }
    for key in keys.prefix(500) { #expect(memory.mark(key: key, quip: quip("句"), now: epoch) == nil) }
    memory.cache(key: keys[0], quip: quip("新"), now: epoch)
    #expect(memory.mark(key: keys[500], quip: quip("句"), now: epoch) == keys[1])
    #expect(memory.status(key: keys[1], now: epoch) == nil)
    #expect(memory.status(key: keys[0], now: epoch)?.cachedQuip?.text == "新")
    #expect(memory.status(key: keys[500], now: epoch)?.isMarked == true)
}
