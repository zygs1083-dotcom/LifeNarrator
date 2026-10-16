import Foundation
import NarratorCore

actor VisionRecorder {
    struct Call: Sendable { let jpeg: Data?; let system: String?; let schema: String }
    var calls: [Call] = []
    nonisolated let changes = AsyncStream<Void>.makeStream()
    func record(jpeg: Data?, system: String?, schema: String) -> String {
        calls.append(Call(jpeg: jpeg, system: system, schema: schema))
        changes.continuation.yield(())
        if schema == GenerationPrompts.chatSchema {
            return #"{"intent":"chat","reply":"我在呢。","rule":null,"setting":null,"memories":[],"forget":null}"#
        }
        if schema.contains("marks") { return #"{"marks":[]}"# }
        return #"{"ok":true}"#
    }
}

struct VisionGenerator: ImageTextGenerator {
    let recorder: VisionRecorder
    var jpeg: Data?
    func attachingJPEG(_ image: Data) -> any TextGenerator {
        var copy = self
        copy.jpeg = image
        return copy
    }
    func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?) async throws -> String {
        await recorder.record(jpeg: jpeg, system: system, schema: schema)
    }
}
