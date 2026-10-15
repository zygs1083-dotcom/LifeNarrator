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

@Test func spriteMemoryExcludeUsesOnlyShownAppHistoryWithinTTLNewestFirst() {
    for (level, ttl) in [(Liveliness.lively, 1800.0), (.rowdy, 900.0)] {
        var memory = SpriteMemory(level: level)
        for i in 0..<15 {
            memory.mark(key: .init(bundleId: "test", text: "Quote \(i)"), quip: quip("句"), now: epoch.addingTimeInterval(Double(i)))
        }
        memory.mark(key: .init(bundleId: "other", text: "other app"), quip: quip("句"), now: epoch.addingTimeInterval(20))
        memory.cache(key: .init(bundleId: "test", text: "never shown"), quip: quip("句"), lineHint: 0, now: epoch.addingTimeInterval(21))
        // Refreshing the cache must not reorder the display history.
        memory.cache(key: .init(bundleId: "test", text: "Quote 3"), quip: quip("句"), lineHint: 0, now: epoch.addingTimeInterval(22))
        #expect(memory.shownQuotes(bundleId: "test", now: epoch.addingTimeInterval(30)) == (3...14).reversed().map { "quote \($0)" })
        #expect(memory.shownQuotes(bundleId: "test", now: epoch.addingTimeInterval(ttl + 14)).isEmpty)
        #expect(memory.shownQuotes(bundleId: "other", now: epoch.addingTimeInterval(30)) == ["other app"])
    }
}

@Test func spriteMemoryCacheExpiresAndIsInvalidatedWhenShown() {
    var memory = SpriteMemory(level: .rowdy)
    let key = SpriteMemory.Key(bundleId: "test", text: "目标")
    memory.cache(key: key, quip: quip("模型句"), lineHint: 2, now: epoch)
    #expect(memory.status(key: key, now: epoch)?.lastMarkedAt == nil)
    #expect(memory.status(key: key, now: epoch.addingTimeInterval(1799.999))?.isCached == true)
    #expect(memory.status(key: key, now: epoch.addingTimeInterval(1800))?.isCached == false)
    memory.mark(key: key, quip: quip("模型句"), lineHint: 2, now: epoch)
    #expect(memory.status(key: key, now: epoch)?.cachedAt == nil)
    #expect(memory.status(key: key, now: epoch.addingTimeInterval(900))?.isMarked == false)
    #expect(memory.status(key: key, now: epoch.addingTimeInterval(1799.999))?.isCached == false)
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
    #expect(memory.screenStatus(key: 0, now: epoch) == nil)
    for key in UInt64(0)..<200 { #expect(memory.recordRequest(key: key, now: epoch) == nil) }
    memory.recordRequest(key: 0, now: epoch.addingTimeInterval(10))
    #expect(memory.screenStatus(key: 0, now: epoch.addingTimeInterval(10))?.requests == 2)
    #expect(memory.screenStatus(key: 0, now: epoch.addingTimeInterval(10))?.lastRequestAt == epoch.addingTimeInterval(10))
    #expect(memory.recordRequest(key: 200, now: epoch) == 1)
    #expect(memory.screenStatus(key: 1, now: epoch) == nil)
    #expect(memory.screenStatus(key: 0, now: epoch.addingTimeInterval(10))?.requests == 2)
}

@Test func spriteMemoryScreenRequestsExpireWithTheQuoteTTL() {
    var memory = SpriteMemory(level: .lively)
    memory.recordRequest(key: 7, now: epoch)
    memory.recordRequest(key: 7, now: epoch)
    #expect(memory.screenStatus(key: 7, now: epoch.addingTimeInterval(1799))?.requests == 2)
    #expect(memory.screenStatus(key: 7, now: epoch.addingTimeInterval(1800)) == nil)
    memory.recordRequest(key: 7, now: epoch.addingTimeInterval(1800))
    #expect(memory.screenStatus(key: 7, now: epoch.addingTimeInterval(1800))?.requests == 1)
}
