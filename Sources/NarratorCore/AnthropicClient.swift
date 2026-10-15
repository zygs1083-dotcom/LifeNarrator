import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AnthropicClient: TextGenerator {
    public var baseURL: URL
    public var path: String
    public var model: String
    public var key: String
    public var stream: Bool
    public var configuration: URLSessionConfiguration

    public init(baseURL: URL, path: String = "messages", model: String, key: String = "", stream: Bool = true,
                configuration: URLSessionConfiguration = .default) {
        self.baseURL = baseURL; self.path = path; self.model = model; self.key = key
        self.stream = stream; self.configuration = configuration
    }

    public func makeRequest(system: String?, prompt: String, schema: String, maxTokens: Int? = nil) throws -> URLRequest {
        var body: [String: Any] = ["model": model, "max_tokens": maxTokens ?? 1024, "stream": stream,
            "messages": [["role": "user", "content": prompt]],
            "tools": [["name": "emit", "input_schema": try JSONSerialization.jsonObject(with: Data(schema.utf8))]],
            "tool_choice": ["type": "tool", "name": "emit"]]
        if let system { body["system"] = system }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?) async throws -> String {
        try await generateJSON(system: system, prompt: prompt, schema: schema, maxTokens: maxTokens, partial: { _ in true })
    }

    public func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?,
                             partial: @escaping @Sendable (String) -> Bool) async throws -> String {
        let request = try makeRequest(system: system, prompt: prompt, schema: schema, maxTokens: maxTokens)
        var parser = SSEParser()
        var body = Data()
        var text = ""
        var toolIndex: Int?
        var initialInput: [String: Any]?
        var stopped = false
        func receive(_ event: String) throws {
            guard let value = try JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any] else { throw ProviderConfigurationError.invalidResponse }
            if value["type"] as? String == "error" { throw HTTPClientError.remote(event) }
            if value["type"] as? String == "message_stop" { stopped = true }
            if value["type"] as? String == "content_block_start",
               let block = value["content_block"] as? [String: Any], block["type"] as? String == "tool_use", block["name"] as? String == "emit" {
                toolIndex = value["index"] as? Int
                initialInput = block["input"] as? [String: Any]
            }
            if value["type"] as? String == "content_block_delta", let index = value["index"] as? Int, index == toolIndex,
               let delta = value["delta"] as? [String: Any], delta["type"] as? String == "input_json_delta",
               let fragment = delta["partial_json"] as? String {
                text += fragment
                if !partial(text) { throw CancellationError() }
            }
        }
        for try await chunk in HTTPStream.bytes(for: request, configuration: configuration) {
            try Task.checkCancellation()
            if stream {
                for event in parser.feed(chunk) { try receive(event) }
                if stopped || parser.done { break }
            } else { body.append(chunk) }
        }
        if stream {
            for event in parser.finish() { try receive(event) }
            if text.isEmpty, let initialInput { text = String(decoding: try JSONSerialization.data(withJSONObject: initialInput), as: UTF8.self) }
        } else {
            guard let value = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw ProviderConfigurationError.invalidResponse }
            if let error = value["error"] { throw HTTPClientError.remote(String(describing: error)) }
            if let blocks = value["content"] as? [[String: Any]],
               let input = blocks.first(where: { $0["type"] as? String == "tool_use" && $0["name"] as? String == "emit" })?["input"] {
                text = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
            }
        }
        guard !text.isEmpty else { throw HTTPClientError.missingGeneratedText }
        return text
    }
}
