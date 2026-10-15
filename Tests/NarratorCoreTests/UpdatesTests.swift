import Foundation
import XCTest
@testable import NarratorCore

final class UpdatesTests: XCTestCase {
    func testSemanticVersionOrdering() throws {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                       "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.2.0", "1.10.0", "2.0.0"]
        for (left, right) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(try SemanticVersion(left), try SemanticVersion(right))
        }
        XCTAssertEqual(try SemanticVersion("v1.2.3+build.1"), try SemanticVersion("1.2.3+build.2"))
        XCTAssertLessThan(try SemanticVersion("1.0.0-999999999999999999999"), try SemanticVersion("1.0.0-1000000000000000000000"))
    }

    func testInvalidSemanticVersions() {
        for value in ["", "1.2", "1.2.3.4", "01.2.3", "1.2.-3", "1.2.3-", "1.2.3-01", "1.2.3-a..b", "1.2.3+", "1.2.3+a+b", "1.2.3-é"] {
            XCTAssertThrowsError(try SemanticVersion(value), value)
        }
    }

    func testChecksums() throws {
        let hash = String(repeating: "aB", count: 32)
        let text = "\(hash)  LifeNarrator.zip\n\(hash) *LifeNarrator.dmg\n"
        XCTAssertEqual(try ReleaseChecksums.sha256(for: "LifeNarrator.zip", in: text), hash.lowercased())
        XCTAssertEqual(try ReleaseChecksums.sha256(for: "LifeNarrator.dmg", in: text), hash.lowercased())
        for invalid in ["", "abcd  LifeNarrator.zip", "\(String(repeating: "g", count: 64))  LifeNarrator.zip", "\(hash)  other.zip", "\(text)\(hash)  LifeNarrator.zip", "broken"] {
            XCTAssertThrowsError(try ReleaseChecksums.sha256(for: "LifeNarrator.zip", in: invalid))
        }
    }

    func testLatestVersionText() throws {
        let release = try AppRelease(versionText: "0.8.1\n")
        XCTAssertEqual(release.tag, "v0.8.1")
        XCTAssertEqual(try AppRelease(versionText: "v0.8.1").tag, "v0.8.1")
        XCTAssertEqual(release.assetURL(named: "LifeNarrator.zip").absoluteString,
                       "https://github.com/zygs1083-dotcom/LifeNarrator/releases/download/v0.8.1/LifeNarrator.zip")
        XCTAssertEqual(release.pageURL.absoluteString, "https://github.com/zygs1083-dotcom/LifeNarrator/releases/tag/v0.8.1")
        for invalid in ["", "<html>", "0.8", "0.8.1 extra"] {
            XCTAssertThrowsError(try AppRelease(versionText: invalid), invalid)
        }
    }
}
