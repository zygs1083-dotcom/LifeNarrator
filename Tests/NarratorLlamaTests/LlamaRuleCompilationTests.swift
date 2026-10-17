import Foundation
import NarratorCore
import XCTest
import llama
@testable import NarratorLlama

final class LlamaRuleCompilationTests: XCTestCase {
    func testAliasGrammarRejectsEmptyAndSingleCharacterAliases() throws {
        guard let path = ProcessInfo.processInfo.environment["NARRATOR_TEST_RULE_MODEL"] else {
            throw XCTSkip("Set NARRATOR_TEST_RULE_MODEL to test the grammar with a real vocabulary.")
        }
        var parameters = llama_model_default_params()
        parameters.vocab_only = true
        let model = try XCTUnwrap(llama_model_load_from_file(path, parameters))
        defer { llama_model_free(model) }
        let vocabulary = try XCTUnwrap(llama_model_get_vocab(model))
        func accepts(_ aliases: String) throws -> Bool {
            let json = #"{"kind":"topic","label":{"zh":"开会","en":"Meeting"},"sentiment":"dislike","note":"","aliases":\#(aliases),"domains":[],"appNames":[],"highlight":false,"variables":{}}"#
            let sampler = try XCTUnwrap(llama_sampler_init_grammar(vocabulary, LlamaGrammar.compiledRule, "root"))
            defer { llama_sampler_free(sampler) }
            var tokens = [llama_token](repeating: 0, count: json.utf8.count)
            let count = llama_tokenize(vocabulary, json, Int32(json.utf8.count), &tokens, Int32(tokens.count), false, false)
            guard count > 0 else { throw LlamaEngine.Failure.tokenization }
            for token in Array(tokens.prefix(Int(count))) + [llama_vocab_eos(vocabulary)] {
                var candidate = llama_token_data(id: token, logit: 0, p: 0)
                withUnsafeMutablePointer(to: &candidate) { pointer in
                    var data = llama_token_data_array(data: pointer, size: 1, selected: -1, sorted: false)
                    llama_sampler_apply(sampler, &data)
                }
                if !candidate.logit.isFinite { return false }
                llama_sampler_accept(sampler, token)
            }
            return true
        }
        XCTAssertFalse(try accepts("[]"))
        XCTAssertFalse(try accepts(#"[""]"#))
        XCTAssertFalse(try accepts(#"["会"]"#))
        XCTAssertTrue(try accepts(#"["开会"]"#))
        XCTAssertTrue(try accepts(#"["O'Connor","AC/DC"]"#))
    }

    func testRuleFixturesCompileWithRealModel() async throws {
        guard let path = ProcessInfo.processInfo.environment["NARRATOR_TEST_RULE_MODEL"] else {
            throw XCTSkip("Set NARRATOR_TEST_RULE_MODEL to a 2B GGUF to run rule compilation integration tests.")
        }
        let generator = LlamaGenerator(modelPath: path)
        addTeardownBlock { await generator.close() }
        typealias Fixture = (input: String, lang: Lang, kind: RuleKind, sentiment: Sentiment, alias: String?)
        let topics: [Fixture] = [
            ("我喜欢纸飞机，看到纸飞机时鼓励我继续创作", .zh, .topic, .like, "纸飞机"),
            ("我喜欢纸飞机", .zh, .topic, .like, "纸飞机"),
            ("我讨厌开会", .zh, .topic, .dislike, "开会"),
        ]
        let controls: [Fixture] = [
            ("我喜欢维基百科", .zh, .site, .like, nil),
            ("我喜欢 Photoshop", .zh, .app, .like, nil),
            ("李明是我同事", .zh, .person, .neutral, nil),
            ("I like Wikipedia", .en, .site, .like, nil),
            ("I like Photoshop", .en, .app, .like, nil),
            ("David is my colleague", .en, .person, .neutral, nil),
        ]
        var previous: [String: String] = [:]
        for (index, fixture) in (topics + topics + controls).enumerated() {
            let raw = try await generator.generateJSON(system: nil,
                prompt: GenerationPrompts.compile(input: fixture.input, lang: fixture.lang),
                schema: GenerationPrompts.compiledRuleSchema, maxTokens: nil)
            let context = "sample \(index + 1), \(fixture.input): \(raw)"
            if let first = previous[fixture.input] { XCTAssertEqual(raw, first, context) }
            previous[fixture.input] = raw
            do {
                let compiled = try JSONDecoder().decode(CompiledRule.self, from: Data(raw.utf8))
                let rule = try RuleCompiler.assemble(compiled, input: fixture.input,
                    now: Date(timeIntervalSince1970: 0), resolveBundleIds: { _ in [] })
                XCTAssertEqual(rule.kind, fixture.kind, context)
                XCTAssertEqual(rule.sentiment, fixture.sentiment, context)
                if let alias = fixture.alias {
                    XCTAssertTrue(rule.match.aliases?.contains(alias) == true, context)
                }
            } catch {
                XCTFail("\(context)\n\(error)")
            }
        }
    }
}
