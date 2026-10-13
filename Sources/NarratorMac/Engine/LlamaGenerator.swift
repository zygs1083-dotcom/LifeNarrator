import Darwin
import Foundation
import NarratorCore

/// Serializes the synchronous `LlamaEngine` on its own queue; loads the model on first use and
/// releases it after 10 idle minutes.
public actor LlamaGenerator: TextGenerator {
    private let queue = DispatchSerialQueue(label: "LifeNarrator.LlamaGenerator", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let modelPath: String
    private var engine: LlamaEngine?
    private var unload: Task<Void, Never>?

    public init(modelPath: String) { self.modelPath = modelPath }

    public func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?) async throws -> String {
        try await generateJSON(system: system, prompt: prompt, schema: schema, maxTokens: maxTokens, partial: { _ in true })
    }

    public var lastPrefillSeconds: Double { engine?.lastPrefillSeconds ?? 0 }

    public func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?,
                             partial: @escaping @Sendable (String) -> Bool) async throws -> String {
        try Task.checkCancellation()
        unload?.cancel()
        defer { scheduleUnload() }
        let grammar = try LlamaGrammar.grammar(for: schema)
        if engine == nil { engine = try LlamaEngine(modelPath: modelPath) }
        var chat = ""
        if let system { chat += "<|im_start|>system\n\(system)<|im_end|>\n" }
        chat += "<|im_start|>user\n\(prompt)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        try Task.checkCancellation()
        return try engine!.generate(prompt: chat, grammar: grammar, maxTokens: maxTokens ?? 1024) {
            !Task.isCancelled && partial($0)
        }
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
