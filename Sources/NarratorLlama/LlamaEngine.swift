import Foundation
import llama
#if os(Windows)
import WinSDK
#endif

public final class LlamaEngine {
    public enum Failure: Error {
        case metalUnavailable, modelLoad, contextCreation, tokenization, emptyOption
        case prefixBoundary, decode(Int32), contextOverflow, cacheRemoval, missingLogits
        case invalidGrammar, tokenPiece, invalidUTF8, generationLimit
        case snapshotSave, snapshotRestore, incompatibleVocabulary, invalidDraftCount, mtpUnavailable
    }

    private static let backend: Void = {
        #if os(Windows)
        let module = GetModuleHandleA("llama.dll")
        var path = [WCHAR](repeating: 0, count: 32768)
        let length = GetModuleFileNameW(module, &path, DWORD(path.count))
        let directory = URL(fileURLWithPath: String(decoding: path.prefix(Int(length)), as: UTF16.self))
            .deletingLastPathComponent().path
        ggml_backend_load_all_from_path(directory)
        #endif
        llama_backend_init()
    }()
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocabulary: OpaquePointer
    private let draft: LlamaEngine?
    private let draftCount: Int
    public private(set) var proposedTokens = 0
    public private(set) var acceptedTokens = 0
    private var cachedPrefix: String?
    private var prefixTokens: [llama_token] = []
    private struct PrefixSnapshot {
        let tokens: [llama_token]
        let data: [UInt8]
    }
    private var generationPrefix: PrefixSnapshot?
    public private(set) var prefixPrefillSeconds = 0.0
    public private(set) var generatedTokens = 0
    public private(set) var lastPrefillSeconds = 0.0
    public private(set) var lastPrefixCached = false
    public private(set) var lastPrefixRestoreSeconds = 0.0
    public var prefixSnapshotBytes: Int { generationPrefix?.data.count ?? 0 }

    public init(modelPath: String, draftModelPath: String? = nil, draftTokens: Int = 6, mtp: Bool = false) throws {
        if mtp { throw Failure.mtpUnavailable }
        guard (1...8).contains(draftTokens) else { throw Failure.invalidDraftCount }
        self.draftCount = draftTokens
        self.draft = try draftModelPath.map { try LlamaEngine(modelPath: $0) }
        _ = Self.backend
        #if os(macOS)
        guard llama_supports_gpu_offload() else { throw Failure.metalUnavailable }
        #endif
        var parameters = llama_model_default_params()
        parameters.n_gpu_layers = llama_supports_gpu_offload() ? -1 : 0
        guard let model = llama_model_load_from_file(modelPath, parameters) else {
            throw Failure.modelLoad
        }
        var configuration = llama_context_default_params()
        configuration.n_ctx = 4096
        configuration.n_batch = 4096
        if draftModelPath != nil { configuration.n_rs_seq = UInt32(draftTokens) }
        guard let context = llama_init_from_model(model, configuration) else {
            llama_model_free(model)
            throw Failure.contextCreation
        }
        self.model = model
        self.context = context
        self.vocabulary = llama_model_get_vocab(model)!
        if let draft {
            guard llama_vocab_n_tokens(vocabulary) == llama_vocab_n_tokens(draft.vocabulary),
                  llama_vocab_bos(vocabulary) == llama_vocab_bos(draft.vocabulary),
                  llama_vocab_eos(vocabulary) == llama_vocab_eos(draft.vocabulary) else {
                throw Failure.incompatibleVocabulary
            }
            for token in 0..<llama_vocab_n_tokens(vocabulary) {
                guard String(cString: llama_vocab_get_text(vocabulary, token)) == String(cString: llama_vocab_get_text(draft.vocabulary, token)),
                      llama_vocab_get_attr(vocabulary, token) == llama_vocab_get_attr(draft.vocabulary, token),
                      llama_vocab_is_eog(vocabulary, token) == llama_vocab_is_eog(draft.vocabulary, token) else {
                    throw Failure.incompatibleVocabulary
                }
            }
        }
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    public func chat(system: String?, user: String) throws -> (prompt: String, prefix: String?) {
        guard let template = llama_model_chat_template(model, nil) else { throw LlamaChat.Failure.missingTemplate }
        var architecture = [CChar](repeating: 0, count: 128)
        let count = llama_model_meta_val_str(model, "general.architecture", &architecture, architecture.count)
        guard count >= 0 && count < architecture.count else { throw LlamaChat.Failure.unsupportedTemplate }
        return try LlamaChat.render(template: String(cString: template), system: system, user: user,
                                    disableThinking: String(cString: architecture).hasPrefix("qwen"))
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

    public func generate(prompt: String, grammar: String, maxTokens: Int,
                         cachePrefix: String? = nil, seed: UInt32 = LLAMA_DEFAULT_SEED,
                         onToken: (String) -> Bool = { _ in true }) throws -> String {
        clear()
        generatedTokens = 0
        lastPrefillSeconds = 0
        lastPrefixCached = false
        lastPrefixRestoreSeconds = 0
        proposedTokens = 0
        acceptedTokens = 0
        let tokens = try tokenize(prompt, special: true)
        guard !tokens.isEmpty else { throw Failure.tokenization }
        let start = ContinuousClock.now
        if let cachePrefix {
            var candidate = try tokenize(cachePrefix, special: true)
            guard tokens.starts(with: candidate) else { throw Failure.prefixBoundary }
            // Sequence snapshots omit logits; leave one token to decode if the prefix is the whole prompt.
            if candidate.count == tokens.count { candidate.removeLast() }
            if let snapshot = generationPrefix, snapshot.tokens == candidate {
                let restoreStart = ContinuousClock.now
                let restored = snapshot.data.withUnsafeBufferPointer {
                    llama_state_seq_set_data(context, $0.baseAddress, $0.count, 0)
                }
                guard restored == snapshot.data.count else { throw Failure.snapshotRestore }
                lastPrefixRestoreSeconds = seconds(since: restoreStart)
                lastPrefixCached = true
            } else {
                generationPrefix = nil
                try evaluate(candidate, position: 0)
                let size = llama_state_seq_get_size(context, 0)
                guard size > 0 else { throw Failure.snapshotSave }
                var data = [UInt8](repeating: 0, count: size)
                let saved = data.withUnsafeMutableBufferPointer {
                    llama_state_seq_get_data(context, $0.baseAddress, $0.count, 0)
                }
                guard saved == size else { throw Failure.snapshotSave }
                generationPrefix = PrefixSnapshot(tokens: candidate, data: data)
            }
            try evaluate(Array(tokens.dropFirst(candidate.count)), position: candidate.count)
        } else {
            try evaluate(tokens, position: 0)
        }
        if let draft {
            guard try draft.tokenize(prompt, special: true) == tokens else { throw Failure.incompatibleVocabulary }
            draft.clear()
            try draft.evaluate(tokens, position: 0)
        }
        lastPrefillSeconds = seconds(since: start)
        let extractingRule = grammar == LlamaGrammar.compiledRule
        if let draft {
            let sampler = try makeSampler(grammar: grammar, seed: seed, distribution: false, extractingRule: extractingRule)
            defer { llama_sampler_free(sampler) }
            return try generateSpeculative(tokens: tokens, sampler: sampler, draft: draft,
                                           maxTokens: maxTokens, seed: seed, onToken: onToken)
        }
        guard let grammarSampler = llama_sampler_init_grammar(vocabulary, grammar, "root") else { throw Failure.invalidGrammar }
        defer { llama_sampler_free(grammarSampler) }
        let sampler = try makeSampler(grammar: nil, seed: seed, distribution: true, extractingRule: extractingRule)
        defer { llama_sampler_free(sampler) }
        var text = ""
        var bytes: [UInt8] = []
        for index in 0..<maxTokens {
            let token = try sample(grammar: grammarSampler, chain: sampler)
            if llama_vocab_is_eog(vocabulary, token) {
                guard let text = String(bytes: bytes, encoding: .utf8) else { throw Failure.invalidUTF8 }
                return text
            }
            bytes += try tokenBytes(token)
            generatedTokens += 1
            // Tokens may split a UTF-8 scalar; still check cancellation on every token.
            if let complete = String(bytes: bytes, encoding: .utf8) { text = complete }
            guard onToken(text) else { throw CancellationError() }
            try evaluate([token], position: tokens.count + index)
        }
        throw Failure.generationLimit
    }

    // Checking all ~250k Qwen tokens against the grammar on every step made decoding about 3x slower, so sample
    // without it and mask the vocabulary only when that token breaks the grammar, as llama.cpp's common sampler does.
    private func sample(grammar: UnsafeMutablePointer<llama_sampler>,
                        chain: UnsafeMutablePointer<llama_sampler>) throws -> llama_token {
        let logits = try logits()
        var token = try select(logits, through: [chain])
        var candidate = llama_token_data(id: token, logit: 0, p: 0)
        withUnsafeMutablePointer(to: &candidate) { pointer in
            var single = llama_token_data_array(data: pointer, size: 1, selected: -1, sorted: false)
            llama_sampler_apply(grammar, &single)
        }
        if !candidate.logit.isFinite { token = try select(logits, through: [grammar, chain]) }
        llama_sampler_accept(grammar, token)
        llama_sampler_accept(chain, token)
        return token
    }

    private func select(_ logits: [Float], through samplers: [UnsafeMutablePointer<llama_sampler>]) throws -> llama_token {
        var candidates = logits.enumerated().map { llama_token_data(id: Int32($0.offset), logit: $0.element, p: 0) }
        return try candidates.withUnsafeMutableBufferPointer { buffer in
            var data = llama_token_data_array(data: buffer.baseAddress, size: buffer.count, selected: -1, sorted: false)
            for sampler in samplers { llama_sampler_apply(sampler, &data) }
            guard data.selected >= 0 else { throw Failure.invalidGrammar }
            return data.data[Int(data.selected)].id
        }
    }

    private func makeSampler(grammar: String?, seed: UInt32, distribution: Bool, extractingRule: Bool) throws -> UnsafeMutablePointer<llama_sampler> {
        let grammarSampler = try grammar.map { grammar in
            guard let sampler = llama_sampler_init_grammar(vocabulary, grammar, "root") else { throw Failure.invalidGrammar }
            return sampler
        }
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        if let grammarSampler { llama_sampler_chain_add(sampler, grammarSampler) }
        if extractingRule {
            // Extraction must preserve names repeated in labels and aliases.
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(0))
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_penalties(llama_vocab_n_tokens(vocabulary), 256, 1.15, 0, 0))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_min_p(0.05, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.9))
        }
        if distribution { llama_sampler_chain_add(sampler, llama_sampler_init_dist(seed)) }
        return sampler
    }

    private func logits(at row: Int32 = -1) throws -> [Float] {
        guard let pointer = llama_get_logits_ith(context, row) else { throw Failure.missingLogits }
        return Array(UnsafeBufferPointer(start: pointer, count: Int(llama_vocab_n_tokens(vocabulary))))
    }

    private func probabilities(_ logits: [Float], sampler: UnsafeMutablePointer<llama_sampler>) throws -> [Double] {
        var candidates = logits.enumerated().map { llama_token_data(id: Int32($0.offset), logit: $0.element, p: 0) }
        return try candidates.withUnsafeMutableBufferPointer { buffer in
            var data = llama_token_data_array(data: buffer.baseAddress, size: buffer.count, selected: -1, sorted: false)
            llama_sampler_apply(sampler, &data)
            let filtered = UnsafeBufferPointer(start: data.data, count: data.size)
            let maximum = filtered.map(\.logit).max()!
            guard maximum.isFinite else { throw Failure.invalidGrammar }
            let weights = filtered.map { exp(Double($0.logit - maximum)) }
            let total = weights.reduce(0, +)
            var probabilities = [Double](repeating: 0, count: logits.count)
            for (candidate, weight) in zip(filtered, weights) { probabilities[Int(candidate.id)] = weight / total }
            return probabilities
        }
    }

    private func saveSequence() throws -> [UInt8] {
        let size = llama_state_seq_get_size(context, 0)
        guard size > 0 else { throw Failure.snapshotSave }
        var data = [UInt8](repeating: 0, count: size)
        let saved = data.withUnsafeMutableBufferPointer { llama_state_seq_get_data(context, $0.baseAddress, $0.count, 0) }
        guard saved == size else { throw Failure.snapshotSave }
        return data
    }

    private func restoreSequence(_ data: [UInt8]) throws {
        let restored = data.withUnsafeBufferPointer { llama_state_seq_set_data(context, $0.baseAddress, $0.count, 0) }
        guard restored == data.count else { throw Failure.snapshotRestore }
    }

    private func generateSpeculative(tokens: [llama_token],
                                     sampler: UnsafeMutablePointer<llama_sampler>, draft: LlamaEngine,
                                     maxTokens: Int, seed: UInt32, onToken: (String) -> Bool) throws -> String {
        var random = SpeculativeRandom(state: seed == LLAMA_DEFAULT_SEED ? UInt64.random(in: .min ... .max) : UInt64(seed))
        var position = tokens.count
        var bytes: [UInt8] = []
        var text = ""
        while generatedTokens < maxTokens {
            try Task.checkCancellation()
            // Sequential draft decodes only retain the last recurrent rollback plane. Save the
            // round boundary so rejection can restore any accepted prefix without corrupting GDN state.
            let snapshot = try draft.saveSequence()
            let proposalSampler = llama_sampler_clone(sampler)!
            defer { llama_sampler_free(proposalSampler) }
            var proposals: [llama_token] = []
            var proposalProbabilities: [[Double]] = []
            let initialLogits = try logits()
            for index in 0..<min(draftCount, maxTokens - generatedTokens) {
                let q = try draft.probabilities(draft.logits(), sampler: proposalSampler)
                let token = llama_token(SpeculativeSampling.sample(q, uniform: random.uniform()))
                proposals.append(token)
                proposalProbabilities.append(q)
                llama_sampler_accept(proposalSampler, token)
                try draft.evaluate([token], position: position + index)
                if llama_vocab_is_eog(vocabulary, token) { break }
            }
            proposedTokens += proposals.count
            try evaluate(proposals, position: position, allLogits: true)
            var committed: [llama_token] = []
            var rejected = false
            for (index, token) in proposals.enumerated() {
                let p = try probabilities(index == 0 ? initialLogits : logits(at: Int32(index - 1)), sampler: sampler)
                let q = proposalProbabilities[index]
                if SpeculativeSampling.accepts(token: Int(token), target: p, draft: q, uniform: random.uniform()) {
                    acceptedTokens += 1
                    committed.append(token)
                    llama_sampler_accept(sampler, token)
                } else {
                    let replacement = llama_token(SpeculativeSampling.sample(
                        SpeculativeSampling.residual(target: p, draft: q), uniform: random.uniform()))
                    committed.append(replacement)
                    llama_sampler_accept(sampler, replacement)
                    rejected = true
                    break
                }
                if llama_vocab_is_eog(vocabulary, token) { break }
            }
            if !rejected && !llama_vocab_is_eog(vocabulary, committed.last!) && generatedTokens + committed.count < maxTokens {
                let p = try probabilities(logits(at: Int32(proposals.count - 1)), sampler: sampler)
                let bonus = llama_token(SpeculativeSampling.sample(p, uniform: random.uniform()))
                committed.append(bonus)
                llama_sampler_accept(sampler, bonus)
            }
            for token in committed {
                if llama_vocab_is_eog(vocabulary, token) {
                    guard let complete = String(bytes: bytes, encoding: .utf8) else { throw Failure.invalidUTF8 }
                    return complete
                }
                bytes += try tokenBytes(token)
                generatedTokens += 1
                if let complete = String(bytes: bytes, encoding: .utf8) { text = complete }
                guard onToken(text) else { throw CancellationError() }
            }
            if rejected {
                let accepted = committed.count - 1
                guard llama_memory_seq_rm(llama_get_memory(context), 0, Int32(position + accepted), -1) else {
                    throw Failure.cacheRemoval
                }
                try evaluate([committed.last!], position: position + accepted)
                try draft.restoreSequence(snapshot)
                try draft.evaluate(committed, position: position)
            } else if committed.count > proposals.count {
                try evaluate([committed.last!], position: position + proposals.count)
                try draft.evaluate([committed.last!], position: position + proposals.count)
            }
            position += committed.count
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

    private func evaluate(_ tokens: [llama_token], position: Int, allLogits: Bool = false) throws {
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
            batch.logits[index] = allLogits || index == tokens.count - 1 ? 1 : 0
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
