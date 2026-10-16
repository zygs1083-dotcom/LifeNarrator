import Foundation
import llama

struct LlamaChat {
    enum Failure: Error { case missingTemplate, unsupportedTemplate }

    static func render(template: String, system: String?, user: String,
                       disableThinking: Bool) throws -> (prompt: String, prefix: String?) {
        func apply(_ messages: [(String, String)], assistant: Bool) throws -> String {
            let strings = messages.flatMap { [strdup($0.0)!, strdup($0.1)!] }
            defer { strings.forEach { free($0) } }
            var chat = messages.indices.map {
                llama_chat_message(role: UnsafePointer(strings[$0 * 2]), content: UnsafePointer(strings[$0 * 2 + 1]))
            }
            let count = llama_chat_apply_template(template, &chat, chat.count, assistant, nil, 0)
            guard count >= 0 else { throw Failure.unsupportedTemplate }
            var buffer = [CChar](repeating: 0, count: Int(count) + 1)
            let written = llama_chat_apply_template(template, &chat, chat.count, assistant, &buffer, Int32(buffer.count))
            guard written == count else { throw Failure.unsupportedTemplate }
            return String(decoding: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        let systemMessages = system.map { [("system", $0)] } ?? []
        var prompt = try apply(systemMessages + [("user", user)], assistant: true)
        if disableThinking { prompt += "<think>\n\n</think>\n\n" }
        let prefix = try system.map { try apply([("system", $0)], assistant: false) }
        return (prompt, prefix.flatMap { !$0.isEmpty && prompt.hasPrefix($0) ? $0 : nil })
    }
}
