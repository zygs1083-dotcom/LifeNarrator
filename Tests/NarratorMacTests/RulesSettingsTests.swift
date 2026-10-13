import Foundation
import NarratorCore
import XCTest
@testable import NarratorMac

@MainActor
final class RulesSettingsTests: XCTestCase {
    func testOfflinePackAndIndividualSwitchesPersist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previousDirectory = ProcessInfo.processInfo.environment["LIFENARRATOR_DATA_DIR"]
        setenv("LIFENARRATOR_DATA_DIR", root.path, 1)
        defer {
            if let previousDirectory { setenv("LIFENARRATOR_DATA_DIR", previousDirectory, 1) }
            else { unsetenv("LIFENARRATOR_DATA_DIR") }
        }
        defer { try! FileManager.default.removeItem(at: root) }
        var settings = AppSettings()
        settings.language = .zhHans
        try AppDataDirectory().saveSettings(settings)
        let store = try AppStore()
        let view = RulesSettingsView(store: store)
        let id = store.builtin.rules[0].id
        let otherID = store.builtin.rules[1].id
        XCTAssertTrue(view.builtinEnabled.wrappedValue)
        view.builtinRuleEnabled(id).wrappedValue = false
        XCTAssertEqual(store.settings.disabledBuiltinIds, [id])
        XCTAssertTrue(view.builtinRuleEnabled(otherID).wrappedValue)
        XCTAssertTrue(view.builtinEnabled.wrappedValue)
        XCTAssertEqual(try store.directory.loadSettings().disabledBuiltinIds, [id])
        view.builtinRuleEnabled(id).wrappedValue = true
        XCTAssertEqual(store.settings.disabledBuiltinIds, [])
        view.builtinEnabled.wrappedValue = false
        let allIDs = Set(store.builtin.rules.map(\.id))
        XCTAssertEqual(store.settings.disabledBuiltinIds, allIDs)
        XCTAssertEqual(try store.directory.loadSettings().disabledBuiltinIds, allIDs)
        XCTAssertFalse(view.builtinEnabled.wrappedValue)
        view.builtinEnabled.wrappedValue = true
        XCTAssertEqual(store.settings.disabledBuiltinIds, [])
        XCTAssertEqual(try store.directory.loadSettings().disabledBuiltinIds, [])
        XCTAssertTrue(view.builtinEnabled.wrappedValue)

        let menu = MenuBarView(store: store)
        for level in [Liveliness.quiet, .lively, .rowdy] {
            store.settings.liveliness = level
            XCTAssertEqual(menu.status, "在岗 · \(store.text("liveliness.\(level.rawValue)"))")
        }
        store.settings.paused = true
        XCTAssertEqual(menu.status, store.text("paused"))
    }
}
