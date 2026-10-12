import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HTTPClientError: Error, Sendable {
    case status(Int, String)
    case missingGeneratedText
}

public struct SystemOneClient: DecisionProvider {
    public var baseURL: URL
    public var key: String
    public var session: URLSession
    public init(baseURL: URL, key: String = "", session: URLSession = .shared) {
        self.baseURL = baseURL; self.key = key; self.session = session
    }
    public func makeRequest(_ decision: DecisionRequest) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/systemone"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(decision)
        return request
    }
    public func decide(_ request: DecisionRequest) async throws -> DecisionResponse {
        let (data, response) = try await session.data(for: makeRequest(request))
        let status = (response as! HTTPURLResponse).statusCode
        guard (200..<300).contains(status) else { throw HTTPClientError.status(status, String(decoding: data, as: UTF8.self)) }
        return try JSONDecoder().decode(DecisionResponse.self, from: data)
    }
}

public protocol TextGenerator: Sendable {
    func generateJSON(system: String?, prompt: String, schema: String) async throws -> String
}

public struct OpenAICompatibleClient: TextGenerator {
    public var baseURL: URL
    public var key: String
    public var model: String
    public var session: URLSession
    public init(baseURL: URL, model: String, key: String = "", session: URLSession = .shared) {
        self.baseURL = baseURL; self.model = model; self.key = key; self.session = session
    }
    public func makeRequest(system: String?, prompt: String, schema: String) throws -> URLRequest {
        var messages: [[String: String]] = []
        if let system { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": prompt])
        let schemaObject = try JSONSerialization.jsonObject(with: Data(schema.utf8))
        let body: [String: Any] = ["model": model, "messages": messages,
            "response_format": ["type": "json_schema", "json_schema": ["name": "lifenarrator", "schema": schemaObject]]]
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    public func generateJSON(system: String?, prompt: String, schema: String) async throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { var content: String? }
                var message: Message
            }
            var choices: [Choice]
        }
        let (data, response) = try await session.data(for: makeRequest(system: system, prompt: prompt, schema: schema))
        let status = (response as! HTTPURLResponse).statusCode
        guard (200..<300).contains(status) else { throw HTTPClientError.status(status, String(decoding: data, as: UTF8.self)) }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let text = decoded.choices.first?.message.content else { throw HTTPClientError.missingGeneratedText }
        return text
    }
}
