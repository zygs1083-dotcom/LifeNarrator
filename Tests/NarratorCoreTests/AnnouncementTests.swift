import XCTest
@testable import NarratorCore

final class AnnouncementTests: XCTestCase {
    func testBundledAnnouncementAndLanguageSelection() throws {
        let notes = try UpdateAnnouncement.load()
        XCTAssertEqual(notes.title.value(.zh), "更新公告")
        XCTAssertEqual(notes.title.value(.en), "What is new")
        XCTAssertEqual(notes.dismiss.value(.en), "Got it")
        XCTAssertEqual(notes.items.count, 4)
        for text in [notes.intro] + notes.items {
            XCTAssertFalse(text.value(.zh).isEmpty)
            XCTAssertFalse(text.value(.en).isEmpty)
            XCTAssertNotEqual(text.value(.zh), text.value(.en))
        }
    }

    func testOnboardingAndSeenVersionGate() {
        XCTAssertFalse(UpdateAnnouncement.shouldShow(onboardingCompleted: false, seenVersion: nil))
        XCTAssertTrue(UpdateAnnouncement.shouldShow(onboardingCompleted: true, seenVersion: nil))
        XCTAssertTrue(UpdateAnnouncement.shouldShow(onboardingCompleted: true, seenVersion: "0.9.9"))
        XCTAssertFalse(UpdateAnnouncement.shouldShow(onboardingCompleted: true, seenVersion: NarratorCore.version))
    }
}
