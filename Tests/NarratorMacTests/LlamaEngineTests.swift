import Foundation
import NarratorMac
import XCTest

final class LlamaEngineTests: XCTestCase {
    private func engine() throws -> LlamaEngine {
        guard let path = ProcessInfo.processInfo.environment["NARRATOR_TEST_MODEL"] else {
            throw XCTSkip("Set NARRATOR_TEST_MODEL to run real GGUF integration tests.")
        }
        return try LlamaEngine(modelPath: path)
    }

    func testCacheMatchesFreshConcatenatedEvaluation() throws {
        let engine = try engine()
        let prefix = "<|im_start|>user\nChoose one letter.\n\n"
        let options = [" A", " B", " C"]
        let firstSuffix = "A is a person; B is an app. Answer:<|im_end|>\n<|im_start|>assistant\n"
        let secondSuffix = "A is an app; B is a person. Answer:<|im_end|>\n<|im_start|>assistant\n"
        let initial = try engine.optionProbabilities(prefix: prefix, suffix: firstSuffix, options: options)
        XCTAssertGreaterThan(engine.prefixPrefillSeconds, 0)
        let cached = try engine.optionProbabilities(prefix: prefix, suffix: secondSuffix, options: options)
        XCTAssertEqual(engine.prefixPrefillSeconds, 0)
        XCTAssertEqual(cached.count, 3)
        XCTAssertEqual(cached.reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertTrue(cached.allSatisfy { $0.isFinite && (0...1).contains($0) })
        let repeated = try engine.optionProbabilities(prefix: prefix, suffix: firstSuffix, options: options)
        for (actual, expected) in zip(repeated, initial) {
            XCTAssertEqual(actual, expected, accuracy: 1e-5)
        }
        let fresh = try engine.optionProbabilities(prefix: "", suffix: prefix + secondSuffix, options: options)
        for (actual, expected) in zip(cached, fresh) {
            // Metal's full and split batches differ slightly in floating-point results.
            XCTAssertEqual(actual, expected, accuracy: 0.005)
        }
        let freshSplit = try engine.optionProbabilities(prefix: prefix, suffix: secondSuffix, options: options)
        for (actual, expected) in zip(cached, freshSplit) {
            XCTAssertEqual(actual, expected, accuracy: 1e-5)
        }
        let emptySuffix = try engine.optionProbabilities(prefix: prefix, suffix: "", options: options)
        let repeatedEmpty = try engine.optionProbabilities(prefix: prefix, suffix: "", options: options)
        for (actual, expected) in zip(emptySuffix, repeatedEmpty) {
            XCTAssertEqual(actual, expected, accuracy: 1e-5)
        }
    }

    func testGrammarAndDecisionAfterGeneration() throws {
        let engine = try engine()
        let prompt = "<|im_start|>user\nWrite JSON.<|im_end|>\n<|im_start|>assistant\n"
        let grammar = #"root ::= "{\"text\":\"你好\"}""#
        let output = try engine.generate(prompt: prompt, grammar: grammar, maxTokens: 32)
        XCTAssertEqual(output, "{\"text\":\"你好\"}")
        XCTAssertGreaterThan(engine.generatedTokens, 0)
        let probabilities = try engine.optionProbabilities(prefix: "Question:\n\n", suffix: "Yes or no?", options: [" yes", " no"])
        XCTAssertGreaterThan(engine.prefixPrefillSeconds, 0)
        XCTAssertEqual(probabilities.reduce(0, +), 1, accuracy: 1e-12)
    }

    func testGenerationPrefixSnapshotReducesPrefill() throws {
        let engine = try engine()
        let system = String(repeating: "Read the screen carefully and return only JSON.\n", count: 100)
        let prefix = "<|im_start|>system\n\(system)<|im_end|>\n"
        let grammar = #"root ::= "{\"text\":\"你好\"}""#
        let first = try engine.generate(
            prompt: prefix + "<|im_start|>user\nScreen one.<|im_end|>\n<|im_start|>assistant\n",
            grammar: grammar, maxTokens: 32, cachePrefix: prefix)
        XCTAssertEqual(first, "{\"text\":\"你好\"}")
        XCTAssertFalse(engine.lastPrefixCached)
        XCTAssertEqual(engine.lastPrefixRestoreSeconds, 0)
        XCTAssertGreaterThan(engine.prefixSnapshotBytes, 0)
        let firstPrefill = engine.lastPrefillSeconds
        let second = try engine.generate(
            prompt: prefix + "<|im_start|>user\nScreen two.<|im_end|>\n<|im_start|>assistant\n",
            grammar: grammar, maxTokens: 32, cachePrefix: prefix)
        XCTAssertEqual(second, "{\"text\":\"你好\"}")
        XCTAssertTrue(engine.lastPrefixCached)
        XCTAssertGreaterThan(engine.lastPrefixRestoreSeconds, 0)
        XCTAssertLessThan(engine.lastPrefillSeconds, firstPrefill * 0.5)
    }

    func testGenerationPrefixReplacementAndCancellation() throws {
        let engine = try engine()
        let prefix = "<|im_start|>system\nReturn JSON.<|im_end|>\n"
        let suffix = "<|im_start|>user\nWrite JSON.<|im_end|>\n<|im_start|>assistant\n"
        let grammar = #"root ::= "{\"text\":\"你好\"}""#
        XCTAssertThrowsError(try engine.generate(prompt: prefix + suffix, grammar: grammar,
                                                maxTokens: 32, cachePrefix: prefix) { _ in false }) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(try engine.generate(prompt: prefix + suffix, grammar: grammar,
                                          maxTokens: 32, cachePrefix: prefix), "{\"text\":\"你好\"}")
        XCTAssertTrue(engine.lastPrefixCached)
        let changed = "<|im_start|>system\nWrite a JSON object.<|im_end|>\n"
        XCTAssertEqual(try engine.generate(prompt: changed + suffix, grammar: grammar,
                                          maxTokens: 32, cachePrefix: changed), "{\"text\":\"你好\"}")
        XCTAssertFalse(engine.lastPrefixCached)
        XCTAssertEqual(try engine.generate(prompt: prefix + suffix, grammar: grammar,
                                          maxTokens: 32, cachePrefix: prefix), "{\"text\":\"你好\"}")
        XCTAssertFalse(engine.lastPrefixCached)
        XCTAssertEqual(try engine.generate(prompt: prefix + suffix, grammar: grammar,
                                          maxTokens: 32), "{\"text\":\"你好\"}")
        XCTAssertFalse(engine.lastPrefixCached)
        XCTAssertEqual(engine.lastPrefixRestoreSeconds, 0)
    }

    func testGenerationWithWholePromptCachedRestoresLogits() throws {
        let engine = try engine()
        let prompt = "<|im_start|>user\nWrite JSON.<|im_end|>\n<|im_start|>assistant\n"
        let grammar = #"root ::= "{\"text\":\"你好\"}""#
        for _ in 0..<2 {
            XCTAssertEqual(try engine.generate(prompt: prompt, grammar: grammar,
                                              maxTokens: 32, cachePrefix: prompt), "{\"text\":\"你好\"}")
        }
        XCTAssertTrue(engine.lastPrefixCached)
    }

    func testTokenCallbackCancelsAndEngineCanGenerateAgain() throws {
        let engine = try engine()
        let prompt = "<|im_start|>user\nWrite JSON.<|im_end|>\n<|im_start|>assistant\n"
        let grammar = #"root ::= "{\"text\":\"你好\"}""#
        var callbacks = 0
        XCTAssertThrowsError(try engine.generate(prompt: prompt, grammar: grammar, maxTokens: 32) { _ in
            callbacks += 1
            return false
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(engine.generatedTokens, 1)
        XCTAssertGreaterThan(engine.lastPrefillSeconds, 0)
        var partials: [String] = []
        let output = try engine.generate(prompt: prompt, grammar: grammar, maxTokens: 32) {
            partials.append($0)
            return true
        }
        XCTAssertEqual(output, "{\"text\":\"你好\"}")
        XCTAssertEqual(partials.last, output)
        XCTAssertEqual(partials.count, engine.generatedTokens)
    }

    func testLibraryFailuresAreExposed() throws {
        let engine = try engine()
        XCTAssertThrowsError(try LlamaEngine(modelPath: ".dev-data/models/missing.gguf"))
        XCTAssertThrowsError(try engine.generate(prompt: "Hello", grammar: "root ::= [", maxTokens: 32))
        XCTAssertThrowsError(try engine.generate(prompt: "Hello", grammar: #"root ::= "hello""#, maxTokens: 1))
        XCTAssertThrowsError(try engine.optionProbabilities(prefix: "", suffix: String(repeating: " word", count: 5000), options: [" A", " B"]))
        let recovered = try engine.optionProbabilities(prefix: "", suffix: "Answer yes or no:", options: [" yes", " no"])
        XCTAssertEqual(recovered.reduce(0, +), 1, accuracy: 1e-12)
    }
}
