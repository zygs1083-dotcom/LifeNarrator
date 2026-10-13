import Foundation
import NarratorCore
@testable import NarratorMac
import XCTest

final class AppSettingsTests: XCTestCase {
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

    func testSameAppWindowSwitchHasItsOwnReason() {
        let change = ContextChange(appChanged: false, windowChanged: true, hostChanged: false)
        XCTAssertEqual(change.reason, .windowChanged)
    }
}
