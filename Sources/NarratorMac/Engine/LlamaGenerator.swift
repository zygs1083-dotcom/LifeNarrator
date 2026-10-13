import Darwin
import Foundation
import NarratorCore

/// Serializes the synchronous `LlamaEngine` on its own queue; loads the model on first use and
/// releases it after 5 idle minutes.
public actor LlamaGenerator: TextGenerator {
    private let queue = DispatchSerialQueue(label: "LifeNarrator.LlamaGenerator", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let modelPath: String
    private var engine: LlamaEngine?
    private var unload: Task<Void, Never>?

    public init(modelPath: String) { self.modelPath = modelPath }

    public func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?) async throws -> String {
        unload?.cancel()
        defer { scheduleUnload() }
        let grammar = try LlamaGrammar.grammar(for: schema)
        if engine == nil { engine = try LlamaEngine(modelPath: modelPath) }
        var chat = ""
        if let system { chat += "<|im_start|>system\n\(system)<|im_end|>\n" }
        chat += "<|im_start|>user\n\(prompt)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        return try engine!.generate(prompt: chat, grammar: grammar, maxTokens: maxTokens ?? 1024)
    }

    private func scheduleUnload() {
        unload = Task {
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
            engine = nil
            // Freed model and compute buffers otherwise stay in the process footprint.
            malloc_zone_pressure_relief(nil, 0)
        }
    }
}
