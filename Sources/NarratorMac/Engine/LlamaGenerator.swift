import Darwin
import Foundation
import NarratorCore
import os

/// Serializes the synchronous `LlamaEngine` on its own queue; loads the model on first use and
/// releases it after 10 idle minutes.
public actor LlamaGenerator: TextGenerator {
    private let queue = DispatchSerialQueue(label: "LifeNarrator.LlamaGenerator", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let modelPath: String
    private var engine: LlamaEngine?
    private var waitForRelease: Task<Void, Never>?
    private var unload: Task<Void, Never>?
    private nonisolated let generating = OSAllocatedUnfairLock(initialState: false)
    public nonisolated var isBusy: Bool { generating.withLock { $0 } }
    private nonisolated let closed = OSAllocatedUnfairLock(initialState: false)

    public init(modelPath: String, waitForRelease: Task<Void, Never>? = nil) {
        self.modelPath = modelPath
        self.waitForRelease = waitForRelease
    }

    public func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?) async throws -> String {
        try await generateJSON(system: system, prompt: prompt, schema: schema, maxTokens: maxTokens, partial: { _ in true })
    }

    public var lastPrefillSeconds: Double { engine?.lastPrefillSeconds ?? 0 }
    public var lastPrefixCached: Bool { engine?.lastPrefixCached ?? false }
    public var lastPrefixRestoreSeconds: Double { engine?.lastPrefixRestoreSeconds ?? 0 }
    public var prefixSnapshotBytes: Int { engine?.prefixSnapshotBytes ?? 0 }

    public func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?,
                             partial: @escaping @Sendable (String) -> Bool) async throws -> String {
        await waitForRelease?.value
        waitForRelease = nil
        try Task.checkCancellation()
        if closed.withLock({ $0 }) { throw CancellationError() }
        unload?.cancel()
        generating.withLock { $0 = true }
        defer {
            generating.withLock { $0 = false }
            scheduleUnload()
        }
        let grammar = try LlamaGrammar.grammar(for: schema)
        if engine == nil { engine = try LlamaEngine(modelPath: modelPath) }
        let cachePrefix = system.map { "<|im_start|>system\n\($0)<|im_end|>\n" }
        var chat = cachePrefix ?? ""
        chat += "<|im_start|>user\n\(prompt)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        try Task.checkCancellation()
        return try engine!.generate(prompt: chat, grammar: grammar, maxTokens: maxTokens ?? 1024,
                                    cachePrefix: cachePrefix) {
            !Task.isCancelled && !closed.withLock({ $0 }) && partial($0)
        }
    }

    /// ggml asserts at exit that its Metal device holds no model buffers, so free the model before quitting.
    /// A running generation stops at its next token, so quitting doesn't wait for it, and nothing loads the model again.
    public nonisolated func close() async {
        closed.withLock { $0 = true }
        await release()
    }

    private func release() {
        unload?.cancel()
        engine = nil
    }

    private func scheduleUnload() {
        unload = Task {
            do { try await Task.sleep(for: .seconds(600)) } catch { return }
            engine = nil
            // Freed model and compute buffers otherwise stay in the process footprint.
            malloc_zone_pressure_relief(nil, 0)
        }
    }
}
