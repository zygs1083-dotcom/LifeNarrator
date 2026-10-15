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

    func testReleaseJSON() throws {
        let json = #"{"tag_name":"v1.2.3","html_url":"https://github.com/zygs1083-dotcom/LifeNarrator/releases/tag/v1.2.3","assets":[{"name":"LifeNarrator.zip","browser_download_url":"https://github.com/zygs1083-dotcom/LifeNarrator/releases/download/v1.2.3/LifeNarrator.zip"},{"name":"checksums.txt","browser_download_url":"https://github.com/zygs1083-dotcom/LifeNarrator/releases/download/v1.2.3/checksums.txt"}]}"#
        let release = try AppRelease.parse(Data(json.utf8))
        XCTAssertEqual(release.tag, "v1.2.3")
        XCTAssertEqual(try release.assetURL(named: "LifeNarrator.zip").lastPathComponent, "LifeNarrator.zip")
        XCTAssertEqual(try release.assetURL(named: "checksums.txt").lastPathComponent, "checksums.txt")
        XCTAssertThrowsError(try release.assetURL(named: "missing"))
        for invalid in ["{}", json.replacingOccurrences(of: "v1.2.3", with: "invalid"), json.replacingOccurrences(of: "https://github.com", with: "http://github.com")] {
            XCTAssertThrowsError(try AppRelease.parse(Data(invalid.utf8)))
        }
        let badAsset = try AppRelease.parse(Data(json.replacingOccurrences(of: "/releases/download/", with: "/elsewhere/").utf8))
        XCTAssertThrowsError(try badAsset.assetURL(named: "LifeNarrator.zip"))
    }
}
