import Foundation
import llama

public final class LlamaEngine {
    public enum Failure: Error {
        case metalUnavailable, modelLoad, contextCreation, tokenization, emptyOption
        case prefixBoundary, decode(Int32), contextOverflow, cacheRemoval, missingLogits
        case invalidGrammar, tokenPiece, invalidUTF8, generationLimit
    }

    private static let backend: Void = llama_backend_init()
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocabulary: OpaquePointer
    private var cachedPrefix: String?
    private var prefixTokens: [llama_token] = []
    public private(set) var prefixPrefillSeconds = 0.0
    public private(set) var generatedTokens = 0

    public init(modelPath: String) throws {
        _ = Self.backend
        guard llama_supports_gpu_offload() else { throw Failure.metalUnavailable }
        var parameters = llama_model_default_params()
        parameters.n_gpu_layers = -1
        guard let model = llama_model_load_from_file(modelPath, parameters) else {
            throw Failure.modelLoad
        }
        var configuration = llama_context_default_params()
        configuration.n_ctx = 2048
        configuration.n_batch = 2048
        guard let context = llama_init_from_model(model, configuration) else {
            llama_model_free(model)
            throw Failure.contextCreation
        }
        self.model = model
        self.context = context
        self.vocabulary = llama_model_get_vocab(model)!
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    public func optionProbabilities(prefix: String, suffix: String, options: [String]) throws -> [Double] {
        let tokens = try tokenize(prefix + suffix, special: true)
        let candidatePrefix = try tokenize(prefix, special: true)
        guard tokens.starts(with: candidatePrefix) else { throw Failure.prefixBoundary }
        guard !tokens.isEmpty else { throw Failure.tokenization }
        let optionTokens = try options.map { option -> llama_token in
            let spaced = option.hasPrefix(" ") ? option : " " + option
            // Qwen splits " 0" into a space token and a digit token.
            guard let first = try tokenize(spaced, special: false).first(where: {
                let bytes = try tokenBytes($0)
                return !bytes.allSatisfy { [9, 10, 13, 32].contains($0) }
            }) else { throw Failure.emptyOption }
            return first
        }
        prefixPrefillSeconds = 0
        if cachedPrefix != prefix {
            clear()
            let start = ContinuousClock.now
            try evaluate(candidatePrefix, position: 0)
            prefixPrefillSeconds = seconds(since: start)
            cachedPrefix = prefix
            prefixTokens = candidatePrefix
        }
        // Re-evaluate the last prefix token for an empty suffix to restore its logits.
        let count = tokens.count == prefixTokens.count ? prefixTokens.count - 1 : prefixTokens.count
        guard llama_memory_seq_rm(llama_get_memory(context), 0, Int32(count), -1) else {
            clear()
            throw Failure.cacheRemoval
        }
        try evaluate(Array(tokens.dropFirst(count)), position: count)
        guard let logits = llama_get_logits_ith(context, -1) else { throw Failure.missingLogits }
        let selected = optionTokens.map { Double(logits[Int($0)]) }
        let maximum = selected.max()!
        let weights = selected.map { exp($0 - maximum) }
        let total = weights.reduce(0, +)
        return weights.map { $0 / total }
    }

    public func generate(prompt: String, grammar: String, maxTokens: Int) throws -> String {
        clear()
        generatedTokens = 0
        guard let grammarSampler = llama_sampler_init_grammar(vocabulary, grammar, "root") else {
            throw Failure.invalidGrammar
        }
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, grammarSampler)
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.8))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED))
        let tokens = try tokenize(prompt, special: true)
        try evaluate(tokens, position: 0)
        var bytes: [UInt8] = []
        for index in 0..<maxTokens {
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocabulary, token) {
                guard let text = String(bytes: bytes, encoding: .utf8) else { throw Failure.invalidUTF8 }
                return text
            }
            bytes += try tokenBytes(token)
            generatedTokens += 1
            try evaluate([token], position: tokens.count + index)
        }
        throw Failure.generationLimit
    }

    private func clear() {
        cachedPrefix = nil
        prefixTokens = []
        llama_memory_clear(llama_get_memory(context), false)
    }

    private func tokenize(_ text: String, special: Bool) throws -> [llama_token] {
        let length = Int32(text.utf8.count)
        let needed = llama_tokenize(vocabulary, text, length, nil, 0, special, special)
        guard needed != Int32.min else { throw Failure.tokenization }
        if needed == 0 { return [] }
        var tokens = [llama_token](repeating: 0, count: Int(abs(needed)))
        let count = llama_tokenize(vocabulary, text, length, &tokens, Int32(tokens.count), special, special)
        guard count >= 0 else { throw Failure.tokenization }
        return Array(tokens.prefix(Int(count)))
    }

    private func tokenBytes(_ token: llama_token) throws -> [UInt8] {
        var piece = [CChar](repeating: 0, count: 256)
        var count = llama_token_to_piece(vocabulary, token, &piece, Int32(piece.count), 0, false)
        if count < 0 {
            piece = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocabulary, token, &piece, Int32(piece.count), 0, false)
        }
        guard count >= 0 else { throw Failure.tokenPiece }
        return piece.prefix(Int(count)).map { UInt8(bitPattern: $0) }
    }

    private func evaluate(_ tokens: [llama_token], position: Int) throws {
        guard position + tokens.count <= Int(llama_n_ctx(context)) else { throw Failure.contextOverflow }
        if tokens.isEmpty { return }
        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }
        batch.n_tokens = Int32(tokens.count)
        for (index, token) in tokens.enumerated() {
            batch.token[index] = token
            batch.pos[index] = Int32(position + index)
            batch.n_seq_id[index] = 1
            batch.seq_id[index]![0] = 0
            batch.logits[index] = index == tokens.count - 1 ? 1 : 0
        }
        let result = llama_decode(context, batch)
        guard result == 0 else {
            clear()
            throw Failure.decode(result)
        }
        llama_synchronize(context)
    }

    private func seconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
}
