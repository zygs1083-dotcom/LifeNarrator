import Foundation
import XCTest
@testable import NarratorLlama

final class LlamaSpeculativeEngineTests: XCTestCase {
    func testSpeculativeGrammarSeedCancellationAndPrefixReuse() throws {
        guard let path = ProcessInfo.processInfo.environment["NARRATOR_TEST_MODEL"] else {
            throw XCTSkip("Set NARRATOR_TEST_MODEL to run real GGUF integration tests.")
        }
        let draftPath = ProcessInfo.processInfo.environment["NARRATOR_TEST_DRAFT_MODEL"] ?? path
        let engine = try LlamaEngine(modelPath: path, draftModelPath: draftPath, draftTokens: 4)
        let chat = try engine.chat(system: "Return JSON.", user: "Choose a greeting.")
        let grammar = #"root ::= "\"" ("A" | "B" | "C") "\"""#
        var outputs: [String] = []
        for _ in 0..<2 {
            outputs.append(try engine.generate(prompt: chat.prompt, grammar: grammar,
                maxTokens: 16, cachePrefix: chat.prefix, seed: 42))
            XCTAssertGreaterThan(engine.proposedTokens, 0)
            XCTAssertLessThanOrEqual(engine.acceptedTokens, engine.proposedTokens)
        }
        XCTAssertEqual(outputs[0], outputs[1])
        XCTAssertTrue(["\"A\"", "\"B\"", "\"C\""].contains(outputs[0]))
        XCTAssertTrue(engine.lastPrefixCached)
        XCTAssertThrowsError(try engine.generate(prompt: chat.prompt, grammar: grammar,
            maxTokens: 16, seed: 42) { _ in false }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try engine.generate(prompt: chat.prompt, grammar: grammar, maxTokens: 16, seed: 42), outputs[0])
        XCTAssertThrowsError(try LlamaEngine(modelPath: path, mtp: true))
    }

}
