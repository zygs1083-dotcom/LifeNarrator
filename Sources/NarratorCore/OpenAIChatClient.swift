import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OpenAIChatClient: TextGenerator {
    public var baseURL: URL
    public var path: String
    public var key: String
    public var model: String
    public var structured: StructuredOutput
    public var stream: Bool
    public var configuration: URLSessionConfiguration

    public init(baseURL: URL, path: String, model: String, key: String = "",
                structured: StructuredOutput = .jsonSchema, stream: Bool = true,
                configuration: URLSessionConfiguration = .default) {
        self.baseURL = baseURL; self.path = path; self.model = model; self.key = key
        self.structured = structured; self.stream = stream; self.configuration = configuration
    }

    public func makeRequest(system: String?, prompt: String, schema: String, maxTokens: Int? = nil) throws -> URLRequest {
        let schemaObject = try JSONSerialization.jsonObject(with: Data(schema.utf8))
        var system = system
        if structured != .jsonSchema {
            system = [system, schema, "只输出符合这个 schema 的 JSON"].compactMap { $0 }.joined(separator: "\n")
        }
        var messages: [[String: String]] = []
        if let system { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": prompt])
        var body: [String: Any] = ["model": model, "messages": messages, "stream": stream]
        switch structured {
        case .jsonSchema: body["response_format"] = ["type": "json_schema", "json_schema": ["name": "lifenarrator", "schema": schemaObject]]
        case .jsonObject: body["response_format"] = ["type": "json_object"]
        case .prompt: break
        }
        if let maxTokens { body["max_tokens"] = maxTokens }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?) async throws -> String {
        try await generateJSON(system: system, prompt: prompt, schema: schema, maxTokens: maxTokens, partial: { _ in true })
    }

    public func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?,
                             partial: @escaping @Sendable (String) -> Bool) async throws -> String {
        let request = try makeRequest(system: system, prompt: prompt, schema: schema, maxTokens: maxTokens)
        var body = Data()
        var parser = SSEParser()
        var text = ""
        func receive(_ event: String) throws {
            let response = try JSONDecoder().decode(Response.self, from: Data(event.utf8))
            if let error = response.error { throw HTTPClientError.remote(error.message) }
            if let content = response.choices?.first?.delta?.content {
                text += content
                if !partial(generatedJSON(text)) { throw CancellationError() }
            }
        }
        for try await chunk in HTTPStream.bytes(for: request, configuration: configuration) {
            try Task.checkCancellation()
            if stream {
                for event in parser.feed(chunk) { try receive(event) }
                if parser.done { break }
            } else { body.append(chunk) }
        }
        if stream {
            for event in parser.finish() { try receive(event) }
        } else {
            let response = try JSONDecoder().decode(Response.self, from: body)
            if let error = response.error { throw HTTPClientError.remote(error.message) }
            guard let content = response.choices?.first?.message?.content else { throw HTTPClientError.missingGeneratedText }
            text = content
        }
        guard !text.isEmpty else { throw HTTPClientError.missingGeneratedText }
        return generatedJSON(text)
    }

    private struct Response: Decodable {
        struct APIError: Decodable { var message: String }
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message?
            var delta: Message?
        }
        var choices: [Choice]?
        var error: APIError?
    }
}
