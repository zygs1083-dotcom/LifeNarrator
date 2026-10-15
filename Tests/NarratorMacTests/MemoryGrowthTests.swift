import Foundation
import NarratorBrain
import XCTest
@testable import NarratorMac

@MainActor
final class MemoryGrowthTests: XCTestCase {
    func testMemoryControlsPersistAndDisablingStopsAdditions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = ProcessInfo.processInfo.environment["LIFENARRATOR_DATA_DIR"]
        setenv("LIFENARRATOR_DATA_DIR", root.path, 1)
        defer {
            if let previous { setenv("LIFENARRATOR_DATA_DIR", previous, 1) }
            else { unsetenv("LIFENARRATOR_DATA_DIR") }
            try! FileManager.default.removeItem(at: root)
        }
        let store = try AppStore()
        let memory = try XCTUnwrap(store.addMemory(kind: .fact, text: "喜欢清晨散步"))
        try store.editMemory(id: memory.id, kind: .preference, text: "最喜欢喝茉莉花茶")
        try store.pinMemory(id: memory.id, pinned: true)
        var restored = try AppStore()
        XCTAssertEqual(restored.memories.first?.text, "最喜欢喝茉莉花茶")
        XCTAssertEqual(restored.memories.first?.kind, .preference)
        XCTAssertEqual(restored.memories.first?.pinned, true)
        restored.settings.memoryEnabled = false
        XCTAssertNil(try restored.addMemory(kind: .nickname, text: "阿王"))
        XCTAssertEqual(restored.memories.count, 1)
        try restored.deleteMemory(id: memory.id)
        restored.settings.memoryEnabled = true
        _ = try restored.addMemory(kind: .nickname, text: "阿王")
        try restored.clearMemories()
        restored = try AppStore()
        XCTAssertTrue(restored.memories.isEmpty)
        XCTAssertNil(restored.error)
    }

    func testUnlockThresholdsAndSpriteName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = ProcessInfo.processInfo.environment["LIFENARRATOR_DATA_DIR"]
        setenv("LIFENARRATOR_DATA_DIR", root.path, 1)
        defer {
            if let previous { setenv("LIFENARRATOR_DATA_DIR", previous, 1) }
            else { unsetenv("LIFENARRATOR_DATA_DIR") }
            try! FileManager.default.removeItem(at: root)
        }
        let directory = try AppDataDirectory()
        let url = root.appendingPathComponent("growth.json")
        for level in [1, 2, 3, 5, 15, 30] {
            var growth = try GrowthTracker(url: url).state
            growth.level = level
            growth.experience = 40 * level * level
            growth.unlocked = Set(GrowthUnlock.allCases.filter { $0.level <= level })
            try JSONEncoder().encode(growth).write(to: url)
            let store = try AppStore()
            store.settings.spriteName = "  星仔  "
            XCTAssertEqual(store.spriteDisplayName, level >= 2 ? "星仔" : store.text("tab.sprite"))
            for unlock in [GrowthUnlock.spriteName, .emoji, .starBubble, .starryTheme] {
                XCTAssertEqual(store.isUnlocked(unlock), level >= unlock.level)
            }
            XCTAssertEqual(try directory.loadSettings().spriteName, "  星仔  ")
        }
    }

    func testNewAppearanceSettingsRoundTripAndLegacyDefaults() throws {
        var settings = AppSettings()
        settings.spriteName = "Stella"
        settings.bubbleStyle.shape = .star
        settings.bubbleStyle.theme = .starry
        settings.bubbleStyle.emoji = "🦊"
        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(restored.spriteName, "Stella")
        XCTAssertEqual(restored.bubbleStyle.shape, .star)
        XCTAssertEqual(restored.bubbleStyle.theme, .starry)
        XCTAssertEqual(restored.bubbleStyle.displayedEmoji(["✨"]), ["🦊"])
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "spriteName")
        var style = json["bubbleStyle"] as! [String: Any]
        style.removeValue(forKey: "emoji")
        json["bubbleStyle"] = style
        let legacy = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.spriteName, "")
        XCTAssertEqual(legacy.bubbleStyle.displayedEmoji(["✨", "☕"]), ["✨"])
        var bubble = restored.bubbleStyle
        bubble.emojiDensity = .none
        XCTAssertEqual(bubble.displayedEmoji(["✨"]), [])
    }
}
