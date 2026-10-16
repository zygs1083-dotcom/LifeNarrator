import XCTest
@testable import narrator_bench

final class CompareArgumentsTests: XCTestCase {
    func testModelsAndDraft() throws {
        let args = try CompareArguments(["--models", "a.gguf,b.gguf", "--draft", "small.gguf", "--draft-tokens", "4"])
        XCTAssertEqual(args.models, ["a.gguf", "b.gguf"])
        XCTAssertEqual(args.draft, "small.gguf")
        XCTAssertEqual(args.draftTokens, 4)
        XCTAssertFalse(args.mtp)
        XCTAssertTrue(try CompareArguments(["--mtp", "--models", "mtp.gguf"]).mtp)
        XCTAssertEqual(try CompareArguments(["--models", "a.gguf"]).draftTokens, 6)
    }

    func testInvalidArguments() {
        for args in [[], ["--models"], ["--models", ""], ["--models", "a,,b"],
                     ["--models", "a", "--models", "b"], ["--models", "a", "--unknown", "x"],
                     ["--models", "a", "--draft"], ["--models", "--mtp"],
                     ["--models", "a", "--draft", "b", "--mtp"],
                     ["--models", "a", "--draft-tokens", "4"],
                     ["--models", "a", "--draft", "b", "--draft-tokens", "0"],
                     ["--models", "a", "--draft", "b", "--draft-tokens", "9"]] {
            XCTAssertThrowsError(try CompareArguments(args), "\(args)")
        }
    }
}
