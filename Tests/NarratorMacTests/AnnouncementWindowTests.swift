import AppKit
import NarratorCore
import XCTest
@testable import NarratorMac

@MainActor
final class AnnouncementWindowTests: XCTestCase {
    func testCloseReopenSingleWindowAndReadPersistence() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = ProcessInfo.processInfo.environment["LIFENARRATOR_DATA_DIR"]
        setenv("LIFENARRATOR_DATA_DIR", root.path, 1)
        defer {
            if let previous { setenv("LIFENARRATOR_DATA_DIR", previous, 1) }
            else { unsetenv("LIFENARRATOR_DATA_DIR") }
            try! FileManager.default.removeItem(at: root)
        }
        let existing = Set(application.windows.map(ObjectIdentifier.init))
        func ownWindows() -> [NSWindow] {
            application.windows.filter { $0 is AnnouncementWindow && !existing.contains(ObjectIdentifier($0)) }
        }
        defer { ownWindows().forEach { $0.close() } }
        let directory = try AppDataDirectory()
        var settings = AppSettings()
        settings.language = .zhHans
        settings.provider = .builtin
        try directory.saveSettings(settings)
        let store = try AppStore()
        // Exercise only announcement presentation; start() registers shortcuts and starts sensing.
        store.showAnnouncement()
        XCTAssertTrue(ownWindows().isEmpty, "Onboarding must retain focus")
        store.settings.onboardingCompleted = true
        XCTAssertTrue(UpdateAnnouncement.shouldShow(onboardingCompleted: true,
                                                   seenVersion: store.settings.seenAnnouncementVersion))
        store.showAnnouncement()
        let first = try XCTUnwrap(ownWindows().first)
        XCTAssertEqual(ownWindows().count, 1)
        XCTAssertTrue(first.isVisible)
        XCTAssertEqual(first.title, "更新公告")
        XCTAssertNil(try directory.loadSettings().seenAnnouncementVersion)
        store.showAnnouncement()
        XCTAssertEqual(ownWindows().count, 1)
        XCTAssertTrue(ownWindows().first === first)
        store.settings.language = .en
        XCTAssertEqual(first.title, "What is new", "Title must update without reopening")
        store.settings.language = .zhHans
        XCTAssertEqual(first.title, "更新公告")

        first.performClose(nil)
        XCTAssertFalse(first.isVisible)
        XCTAssertEqual(try directory.loadSettings().seenAnnouncementVersion, NarratorCore.version)
        let restarted = try AppStore()
        XCTAssertFalse(UpdateAnnouncement.shouldShow(onboardingCompleted: restarted.settings.onboardingCompleted,
                                                    seenVersion: restarted.settings.seenAnnouncementVersion))

        // Settings may reopen already-read notes, reusing the same native window.
        store.showAnnouncement()
        store.showAnnouncement()
        XCTAssertEqual(ownWindows().count, 1)
        XCTAssertTrue(ownWindows().first === first)
        XCTAssertTrue(first.isVisible)
        store.settings.seenAnnouncementVersion = "0.9.10"
        first.close()
        XCTAssertFalse(first.isVisible)
        XCTAssertEqual(try directory.loadSettings().seenAnnouncementVersion, NarratorCore.version)
        XCTAssertNil(store.error)
        XCTAssertNil(restarted.error)
    }
}
