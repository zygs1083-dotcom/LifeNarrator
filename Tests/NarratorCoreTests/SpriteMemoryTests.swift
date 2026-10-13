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
        memory.cache(key: key, quip: quip("你好"), lineHint: 7, now: epoch)
        memory.mark(key: key, quip: quip("你好"), lineHint: 7, now: epoch)
        #expect(memory.status(key: key, now: epoch.addingTimeInterval(ttl - 0.001))?.isMarked == true)
        #expect(memory.status(key: key, now: epoch.addingTimeInterval(ttl))?.isMarked == false)
        #expect(memory.status(key: key, now: epoch)?.quip.text == "你好")
        #expect(memory.status(key: key, now: epoch)?.lineHint == 7)
    }
}

@Test func spriteMemoryLeastRecentUsesSixtySecondMinimum() {
    var memory = SpriteMemory()
    let keys = (0..<3).map { SpriteMemory.Key(bundleId: "test", text: String($0)) }
    memory.mark(key: keys[0], quip: quip("早"), now: epoch)
    memory.mark(key: keys[1], quip: quip("晚"), now: epoch.addingTimeInterval(5))
    #expect(memory.leastRecent(among: keys, now: epoch.addingTimeInterval(59.999)) == nil)
    #expect(memory.leastRecent(among: keys.reversed(), now: epoch.addingTimeInterval(60)) == keys[0])
    #expect(memory.leastRecent(among: [keys[1], keys[2]], now: epoch.addingTimeInterval(65)) == keys[1])
}

@Test func spriteMemoryCacheTTLIsIndependentOfMarkTTL() {
    var memory = SpriteMemory(level: .rowdy)
    let key = SpriteMemory.Key(bundleId: "test", text: "目标")
    memory.cache(key: key, quip: quip("模型句"), lineHint: 2, now: epoch)
    #expect(memory.status(key: key, now: epoch)?.lastMarkedAt == nil)
    memory.mark(key: key, quip: quip("模型句"), lineHint: 2, now: epoch)
    #expect(memory.status(key: key, now: epoch.addingTimeInterval(900))?.isMarked == false)
    #expect(memory.status(key: key, now: epoch.addingTimeInterval(1799.999))?.isCached == true)
    #expect(memory.status(key: key, now: epoch.addingTimeInterval(1800))?.isCached == false)
    #expect(memory.keys(bundleId: "other").isEmpty)
}

@Test func spriteMemoryMarkLRUEvictsBeyondFiveHundred() {
    var memory = SpriteMemory()
    let keys = (0...500).map { SpriteMemory.Key(bundleId: "test", text: String($0)) }
    for key in keys.prefix(500) { #expect(memory.mark(key: key, quip: quip("句"), now: epoch) == nil) }
    memory.cache(key: keys[0], quip: quip("新"), lineHint: 0, now: epoch)
    #expect(memory.mark(key: keys[500], quip: quip("句"), now: epoch) == keys[1])
    #expect(memory.status(key: keys[1], now: epoch) == nil)
    #expect(memory.status(key: keys[0], now: epoch)?.quip.text == "新")
    #expect(memory.status(key: keys[500], now: epoch)?.isMarked == true)
}

@Test func spriteMemoryScreenCountsAndLRUEvictsBeyondTwoHundred() {
    var memory = SpriteMemory()
    #expect(memory.screenStatus(key: 0) == nil)
    for key in UInt64(0)..<200 { #expect(memory.recordRequest(key: key, now: epoch) == nil) }
    memory.recordRequest(key: 0, now: epoch.addingTimeInterval(10))
    #expect(memory.screenStatus(key: 0)?.requests == 2)
    #expect(memory.screenStatus(key: 0)?.lastRequestAt == epoch.addingTimeInterval(10))
    #expect(memory.recordRequest(key: 200, now: epoch) == 1)
    #expect(memory.screenStatus(key: 1) == nil)
    #expect(memory.screenStatus(key: 0)?.requests == 2)
}
