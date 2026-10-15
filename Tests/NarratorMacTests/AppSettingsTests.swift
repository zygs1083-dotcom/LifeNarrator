import Foundation
import NarratorCore
@testable import NarratorMac
import XCTest

final class AppSettingsTests: XCTestCase {
    func testLegacyPersonaStringAndCustomIDRoundTrip() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as! [String: Any]
        json["persona"] = "sharp"
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json)).persona, .sharp)
        json["persona"] = "custom.example"
        let custom = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(custom.persona.rawValue, "custom.example")
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(custom)).persona, custom.persona)
    }

    func testAutomaticUpdatesDefaultAndPersistence() throws {
        var original = AppSettings()
        XCTAssertTrue(original.automaticUpdates)
        original.automaticUpdates = false
        let data = try JSONEncoder().encode(original)
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: data).automaticUpdates)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "automaticUpdates")
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json)).automaticUpdates)
    }

    func testEffectiveDwellExtendsForMoreThanThreeMarksWithoutChangingSettings() {
        var style = BubbleStyle()
        for (count, seconds, expected) in [(1, 3.0, 3.0), (3, 3, 3), (4, 3, 10),
                                          (5, 3, 12.5), (10, 3, 25), (10, 30, 30)] {
            style.maxOnScreen = count
            style.dwell = .seconds(seconds)
            XCTAssertEqual(OverlayController.dwellSeconds(seconds, maxOnScreen: style.maxOnScreen), expected)
            XCTAssertEqual(style.dwell, .seconds(seconds))
        }
    }

    func testOldFrequencyKeysAreIgnoredAndMissingLivelinessDefaultsToLively() throws {
        var original = AppSettings()
        original.bubbleStyle.theme = .macaron
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json.removeValue(forKey: "liveliness")
        json["ruleCooldown"] = 600
        json["globalPerMinute"] = 3
        json["minGap"] = 5
        let settings = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(settings.liveliness, .lively)
        XCTAssertEqual(settings.bubbleStyle.theme, .macaron)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        XCTAssertNil(encoded["ruleCooldown"])
        XCTAssertNil(encoded["globalPerMinute"])
        XCTAssertNil(encoded["minGap"])
    }

    func testLivelinessRoundTripsAndOtherMissingRequiredKeysStillThrow() throws {
        for level in [Liveliness.quiet, .lively, .rowdy] {
            var original = AppSettings()
            original.liveliness = level
            let settings = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(original))
            XCTAssertEqual(settings.liveliness, level)
        }
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as! [String: Any]
        json.removeValue(forKey: "provider")
        XCTAssertThrowsError(try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    func testMissingMarkGapDefaultsToTwoAndRoundTrips() throws {
        var original = AppSettings()
        original.markGap = 9
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data).markGap, 9)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["markGap"] as? Double, 9)
        json.removeValue(forKey: "markGap")
        json["minGap"] = 5
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.markGap, 2)
    }

    func testDwellIsClampedAndMissingDwellStaysUntilDismissed() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as! [String: Any]
        var style = json["bubbleStyle"] as! [String: Any]
        for (value, expected) in [(45.0, 30.0), (0, 1), (3, 3)] {
            style["dwell"] = value
            json["bubbleStyle"] = style
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(decoded.bubbleStyle.dwell, .seconds(expected))
        }
        style.removeValue(forKey: "dwell")
        json["bubbleStyle"] = style
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.bubbleStyle.dwell, .untilDismissed)
    }

    @MainActor
    func testMarkGapPersistsAndConfiguresEngineAcrossLivelinessLevels() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previousDirectory = ProcessInfo.processInfo.environment["LIFENARRATOR_DATA_DIR"]
        setenv("LIFENARRATOR_DATA_DIR", root.path, 1)
        defer {
            if let previousDirectory { setenv("LIFENARRATOR_DATA_DIR", previousDirectory, 1) }
            else { unsetenv("LIFENARRATOR_DATA_DIR") }
        }
        defer { try! FileManager.default.removeItem(at: root) }
        let store = try AppStore()
        store.settings.markGap = 9
        XCTAssertEqual(try store.directory.loadSettings().markGap, 9)
        let engine = try NarratorEngine(store: store)
        for level in [Liveliness.quiet, .lively, .rowdy] {
            store.settings.liveliness = level
            engine.configure()
            let scheduler = Mirror(reflecting: engine).descendant("scheduler") as! Scheduler
            XCTAssertEqual(scheduler.settings.minGap, 9)
            XCTAssertEqual(store.settings.markGap, 9)
            print("markGap=\(store.settings.markGap) scheduler.minGap=\(scheduler.settings.minGap) level=\(level.rawValue)")
        }
    }

    @MainActor
    func testSaidHistoryStartsEmptyPersistsHashesAndExposesCorruptFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previousDirectory = ProcessInfo.processInfo.environment["LIFENARRATOR_DATA_DIR"]
        setenv("LIFENARRATOR_DATA_DIR", root.path, 1)
        defer {
            if let previousDirectory { setenv("LIFENARRATOR_DATA_DIR", previousDirectory, 1) }
            else { unsetenv("LIFENARRATOR_DATA_DIR") }
        }
        defer { try! FileManager.default.removeItem(at: root) }
        let store = try AppStore()
        let now = Date()
        XCTAssertTrue(store.said.recent(8).isEmpty)
        XCTAssertEqual(store.directory.said.lastPathComponent, "said.json")
        try store.recordSaid("private screen remark", now: now)
        XCTAssertEqual(store.said.recent(8), ["private screen remark"])
        let restored = try AppStore()
        XCTAssertTrue(restored.said.isRepeat("private screen remark", now: now))
        XCTAssertTrue(restored.said.recent(8).isEmpty)
        XCTAssertFalse(try String(contentsOf: store.directory.said, encoding: .utf8).contains("private"))
        try Data("invalid JSON".utf8).write(to: store.directory.said)
        XCTAssertThrowsError(try AppStore())
    }

    func testSameAppWindowSwitchHasItsOwnReason() {
        let change = ContextChange(appChanged: false, windowChanged: true, hostChanged: false)
        XCTAssertEqual(change.reason, .windowChanged)
    }
}
