import Foundation
import NarratorCore
@testable import NarratorMac
import XCTest

final class AppSettingsTests: XCTestCase {
    @MainActor
    func testAPIClientErrorsShareOneAlertExceptRateLimits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previousDirectory = ProcessInfo.processInfo.environment["LIFENARRATOR_DATA_DIR"]
        setenv("LIFENARRATOR_DATA_DIR", root.path, 1)
        defer {
            if let previousDirectory { setenv("LIFENARRATOR_DATA_DIR", previousDirectory, 1) }
            else { unsetenv("LIFENARRATOR_DATA_DIR") }
            try! FileManager.default.removeItem(at: root)
        }
        let store = try AppStore()
        let host = MacBrainHost(store: store)
        host.reportNow(HTTPClientError.status(429, "rate limited"))
        XCTAssertNil(store.error)
        XCTAssertFalse(host.keyRejectedShown)
        for code in [400, 401, 403, 422] {
            host.keyRejectedShown = false
            host.reportNow(HTTPClientError.status(code, "provider refused"))
            let message = (code == 401 || code == 403 ? store.text("api.keyRejected") + "\n" : "") + "\(code): provider refused"
            XCTAssertEqual(store.error, message)
            XCTAssertTrue(host.keyRejectedShown)
            for next in [400, 401, 403, 429] {
                host.reportNow(HTTPClientError.status(next, "later error"))
                XCTAssertEqual(store.error, message)
            }
        }
    }

    func testChatShortcutDefaultMigrationCustomizationAndRemoval() throws {
        var settings = AppSettings()
        let shortcut = settings.chatShortcut
        XCTAssertNotNil(shortcut)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        json.removeValue(forKey: "chatShortcut")
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json)).chatShortcut, shortcut)
        settings.chatShortcut = settings.inputShortcut
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).chatShortcut, settings.inputShortcut)
        settings.chatShortcut = nil
        XCTAssertNil(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).chatShortcut)
    }

    func testLegacyPersonaStringAndCustomIDRoundTrip() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as! [String: Any]
        json["persona"] = "sharp"
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json)).persona, .sharp)
        json["persona"] = "custom.example"
        let custom = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(custom.persona.rawValue, "custom.example")
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(custom)).persona, custom.persona)
    }

    func testMemoryEnabledDefaultsAndRoundTrips() throws {
        var settings = AppSettings()
        XCTAssertTrue(settings.memoryEnabled)
        settings.memoryEnabled = false
        let data = try JSONEncoder().encode(settings)
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: data).memoryEnabled)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "memoryEnabled")
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json)).memoryEnabled)
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

    func testLegacyProviderAndBuiltinModelMigration() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as! [String: Any]
        json["provider"] = "openAICompatible"
        json["generationAPI"] = ["baseURL": "https://legacy.test", "model": "old-model"]
        json.removeValue(forKey: "builtinModel")
        let settings = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(settings.provider, .api)
        XCTAssertEqual(settings.generationAPI.presetID, "custom-openai")
        XCTAssertEqual(settings.generationAPI.baseURL, "https://legacy.test/v1")
        XCTAssertEqual(settings.generationAPI.model, "old-model")
        XCTAssertEqual(settings.builtinModel, ModelCatalog.models[0].name)
        var updated = settings
        updated.builtinModel = ModelCatalog.models[1].name
        updated.generationAPI = ProviderConfiguration(presetID: "anthropic", model: "fixture")
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(restored.builtinModel, ModelCatalog.models[1].name)
        XCTAssertEqual(restored.generationAPI.presetID, "anthropic")
        XCTAssertNil(restored.generationAPI.baseURL)
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
            let brain = try XCTUnwrap(Mirror(reflecting: engine).descendant("brain") as? SpriteBrain)
            let scheduler = Mirror(reflecting: brain).descendant("scheduler") as! Scheduler
            XCTAssertEqual(scheduler.settings.minGap, 9)
            XCTAssertEqual(store.settings.markGap, 9)
            print("markGap=\(store.settings.markGap) scheduler.minGap=\(scheduler.settings.minGap) level=\(level.rawValue)")
        }
    }

    @MainActor
    func testSaidPathIsPassedToBrainAndCorruptionIsExposed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previousDirectory = ProcessInfo.processInfo.environment["LIFENARRATOR_DATA_DIR"]
        setenv("LIFENARRATOR_DATA_DIR", root.path, 1)
        defer {
            if let previousDirectory { setenv("LIFENARRATOR_DATA_DIR", previousDirectory, 1) }
            else { unsetenv("LIFENARRATOR_DATA_DIR") }
        }
        defer { try! FileManager.default.removeItem(at: root) }
        let store = try AppStore()
        XCTAssertEqual(store.directory.said.lastPathComponent, "said.json")
        let engine = try NarratorEngine(store: store)
        let brain = try XCTUnwrap(Mirror(reflecting: engine).descendant("brain") as? SpriteBrain)
        XCTAssertEqual(Mirror(reflecting: brain).descendant("saidURL") as? URL, store.directory.said)
        try Data("invalid JSON".utf8).write(to: store.directory.said)
        XCTAssertThrowsError(try NarratorEngine(store: store))
    }

    func testSameAppWindowSwitchHasItsOwnReason() {
        let change = ContextChange(appChanged: false, windowChanged: true, hostChanged: false)
        XCTAssertEqual(change.reason, .windowChanged)
    }
}
