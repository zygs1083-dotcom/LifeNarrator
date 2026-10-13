import Foundation
import NarratorCore
import NarratorMac
import llama

private final class SpriteTokenizer {
    private let model: OpaquePointer
    private let vocabulary: OpaquePointer

    init(modelPath: String) throws {
        llama_backend_init()
        var parameters = llama_model_default_params()
        parameters.vocab_only = true
        parameters.n_gpu_layers = 0
        guard let model = llama_model_load_from_file(modelPath, parameters) else {
            throw LlamaEngine.Failure.modelLoad
        }
        self.model = model
        vocabulary = llama_model_get_vocab(model)!
    }

    deinit { llama_model_free(model) }

    func count(_ text: String, special: Bool) throws -> Int {
        let length = Int32(text.utf8.count)
        let needed = llama_tokenize(vocabulary, text, length, nil, 0, special, special)
        guard needed != Int32.min else { throw LlamaEngine.Failure.tokenization }
        if needed == 0 { return 0 }
        var tokens = [llama_token](repeating: 0, count: Int(abs(needed)))
        let count = llama_tokenize(vocabulary, text, length, &tokens, Int32(tokens.count), special, special)
        guard count >= 0 else { throw LlamaEngine.Failure.tokenization }
        return Int(count)
    }
}

private final class SpriteTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var stream = SpriteMarkStream()
    private var first: Double?
    private var partials = 0
    private var error: (any Error)?
    private let start = ContinuousClock.now

    func receive(_ partial: String) -> Bool {
        lock.withLock {
            partials += 1
            do {
                let marks = try stream.feed(partial)
                if first == nil && !marks.isEmpty { first = elapsed(start) * 1000 }
            } catch { self.error = error }
            return error == nil
        }
    }

    func result(hasMarks: Bool) throws -> (first: Any, total: Double, streaming: Bool) {
        try lock.withLock {
            if let error { throw error }
            let total = elapsed(start) * 1000
            return (first.map { $0 as Any } ?? (hasMarks ? total as Any : NSNull()), total, partials > 0)
        }
    }
}

private func emitSprite(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

func runSprite(modelPath: String) async throws {
    let tokenizer = try SpriteTokenizer(modelPath: modelPath)
    let generator = LlamaGenerator(modelPath: modelPath)
    try emitSprite([
        "type": "sprite-bench", "model": modelPath, "screens": spriteCases.count, "runs_per_screen": 3,
        "k": 3, "persona": "sharp",
        "prefill_note": "prefill_ms includes prefix snapshot save/restore and remaining prompt decoding; prefix_restore_ms measures restore only.",
        "first_note": "first_ms measures streaming first-mark latency. The first request includes model loading.",
    ])
    var totalMarks = 0
    var totalLocated = 0
    for sample in spriteCases {
        let snapshot = sample.snapshot
        let screen = SpritePrompt.screen(in: snapshot)
        let prompt = GenerationPrompts.spriteMarks(app: snapshot.appName, title: sample.id, screen: screen,
            exclude: [], persona: .sharp, lang: sample.lang, k: 3)
        // Match LlamaGenerator's chat serialization, including the non-thinking assistant prefix.
        let chat = "<|im_start|>system\n\(prompt.system)<|im_end|>\n<|im_start|>user\n\(prompt.user)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        let promptTokens = try tokenizer.count(chat, special: true)
        let screenTokens = try tokenizer.count(screen.text, special: false)
        let estimated = SpritePrompt.estimatedTokens(chat)
        try emitSprite([
            "type": "screen", "case": sample.id, "lang": sample.lang.rawValue,
            "original_text": sample.text, "screen_text": screen.text,
            "prompt_tokens": promptTokens, "prompt_estimated_tokens": estimated,
            "prompt_estimate_delta": estimated - Double(promptTokens),
            "screen_tokens": screenTokens, "screen_estimated_tokens": screen.tokens,
            "screen_estimate_delta": screen.tokens - screenTokens,
            "screen_estimate_error_percent": Double(screen.tokens - screenTokens) / Double(screenTokens) * 100,
        ])
        let lines = screen.lines.map { snapshot.textLines[$0.lineIndex] }
        for run in 1...3 {
            let timing = SpriteTiming()
            let output = try await generator.generateJSON(system: prompt.system, prompt: prompt.user,
                schema: GenerationPrompts.spriteMarksSchema, maxTokens: SpriteGenerator.maxTokens,
                partial: { timing.receive($0) })
            struct Batch: Decodable { let marks: [RawMark] }
            let batch = try JSONDecoder().decode(Batch.self, from: Data(output.utf8))
            let measured = try timing.result(hasMarks: !batch.marks.isEmpty)
            var located = 0
            let marks: [[String: Any]] = batch.marks.map { mark in
                let hit = SpriteLocator.locate(quote: mark.q, lineHint: mark.l, in: lines)
                if hit != nil { located += 1 }
                let reason: String
                if let hit {
                    reason = hit.range == lines[hit.lineIndex].text.startIndex..<lines[hit.lineIndex].text.endIndex
                        ? "whole_line" : "located"
                } else if ["", " ", "\n"].contains(where: { lines.map(\.text).joined(separator: $0).contains(mark.q) }) {
                    reason = "cross_line"
                } else { reason = "rewritten_or_not_on_screen" }
                return ["l": mark.l, "q": mark.q, "t": mark.t, "e": mark.e,
                    "located": hit != nil, "reason": reason,
                    "located_line": hit.map { $0.lineIndex as Any } ?? NSNull()]
            }
            totalMarks += batch.marks.count
            totalLocated += located
            try emitSprite([
                "type": "sprite-run", "case": sample.id, "run": run, "cold": sample.id == spriteCases[0].id && run == 1,
                "mode": measured.streaming ? "streaming" : "non-streaming",
                "prompt_tokens": promptTokens, "prefill_ms": await generator.lastPrefillSeconds * 1000,
                "prefix_cached": await generator.lastPrefixCached,
                "prefix_restore_ms": await generator.lastPrefixRestoreSeconds * 1000,
                "prefix_snapshot_bytes": await generator.prefixSnapshotBytes,
                "first_ms": measured.first, "total_ms": measured.total,
                "located": located, "marks": batch.marks.count, "items": marks, "raw_output": output,
            ])
        }
    }
    try emitSprite([
        "type": "sprite-complete", "runs": spriteCases.count * 3, "located": totalLocated, "marks": totalMarks,
        "location_percent": totalMarks == 0 ? NSNull() : Double(totalLocated) / Double(totalMarks) * 100 as Any,
    ])
}
