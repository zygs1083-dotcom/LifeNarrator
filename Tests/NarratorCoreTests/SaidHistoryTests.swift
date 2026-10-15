import Foundation
import Testing
@testable import NarratorCore

@Test func saidHistoryNormalizesPunctuationSymbolsEmojiAndCase() {
    var said = SaidHistory()
    said.record("Coffee, PLEASE! ☕", now: epoch)
    #expect(said.isRepeat("Coffee, PLEASE! ☕", now: epoch))
    #expect(said.isRepeat("coffee please... 🌷", now: epoch))
    #expect(SaidHistory.normalizedText("Hi 你，１２3!™😬") == "hi你１２3")
    #expect(SaidHistory.normalizedText("カ・ナ © ™ 🌷 ²") == "カナ²")
    #expect(SaidHistory.textHash("Hello!") == 0x4f9f2cab)
    #expect(SaidHistory.textHash("Hello 🌷") == SaidHistory.textHash("HELLO!"))
}

@Test func saidHistoryUsesCJKBigramAndOtherTrigramJaccard() {
    for (original, similar, different) in [
        ("昨晚星星睡着了", "昨晚星星睡着啦", "钱包快躲起来"),
        ("The coffee is getting cold", "The coffee is getting colder", "A tiny holiday awaits")
    ] {
        var said = SaidHistory()
        said.record(original, now: epoch)
        #expect(said.isRepeat(similar, now: epoch))
        #expect(!said.isRepeat(different, now: epoch))
    }
    #expect(SaidHistory.shingles("中文abc").count == 4)
    #expect(SaidHistory.shingles("abcde").count == 3)
    #expect(SaidHistory.shingles("你").count == 1)
    var short = SaidHistory()
    short.record("好！", now: epoch)
    #expect(short.isRepeat("好🌷", now: epoch))
    #expect(!short.isRepeat("好的", now: epoch))
    var threshold = SaidHistory()
    threshold.record("abcd", now: epoch)
    #expect(threshold.isRepeat("abc", now: epoch)) // One of two trigrams: exactly 0.5.
    #expect(!threshold.isRepeat("abce", now: epoch))
}

@Test func saidHistoryExpiresAfter24HoursAndPrunesOnRecord() throws {
    var said = SaidHistory()
    said.record("old private phrase", now: epoch)
    #expect(said.isRepeat("old private phrase", now: epoch.addingTimeInterval(86399.999)))
    #expect(!said.isRepeat("old private phrase", now: epoch.addingTimeInterval(86400)))
    said.record("new phrase", now: epoch.addingTimeInterval(86400))
    #expect(said.recent(8) == ["new phrase"])
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(said)) as! [String: Any]
    #expect((json["entries"] as! [Any]).count == 1)
}

@Test func saidHistoryPersistsOnlyHashesAndTimesAndKeepsRecentOriginalsInMemory() throws {
    var said = SaidHistory()
    said.record("first private phrase", now: epoch)
    said.record("second secret sentence", now: epoch.addingTimeInterval(1))
    #expect(said.recent(1) == ["second secret sentence"])
    #expect(said.recent(8) == ["second secret sentence", "first private phrase"])
    #expect(said.recent(0).isEmpty)
    let data = try JSONEncoder().encode(said)
    let encoded = String(decoding: data, as: UTF8.self)
    #expect(!encoded.contains("private"))
    #expect(!encoded.contains("secret"))
    let decoded = try JSONDecoder().decode(SaidHistory.self, from: data)
    #expect(decoded.recent(8).isEmpty)
    #expect(decoded.isRepeat("first private phrase", now: epoch))
    #expect(decoded.isRepeat("second secret sentence", now: epoch))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(Set(json.keys) == ["entries"])
    for entry in json["entries"] as! [[String: Any]] {
        #expect(Set(entry.keys) == ["hashes", "time"])
        #expect(entry["hashes"] is [NSNumber])
    }
}

@Test func saidHistoryKeepsAtMost1000Entries() throws {
    var said = SaidHistory()
    said.record("unique discarded phrase", now: epoch)
    for i in 0..<1000 { said.record("entry \(i)", now: epoch) }
    #expect(said.recent(1001).count == 1000)
    #expect(!said.isRepeat("unique discarded phrase", now: epoch))
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(said)) as! [String: Any]
    #expect((json["entries"] as! [Any]).count == 1000)
}
