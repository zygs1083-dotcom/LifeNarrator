import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HTTPClientError: Error, Sendable {
    case status(Int, String)
    case missingGeneratedText
    case remote(String)
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
        request.timeoutInterval = 0.8
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
    func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?,
                      partial: @escaping @Sendable (String) -> Bool) async throws -> String
    func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?) async throws -> String
}

public extension TextGenerator {
    func generateJSON(system: String?, prompt: String, schema: String, maxTokens: Int?,
                      partial: @escaping @Sendable (String) -> Bool) async throws -> String {
        try await generateJSON(system: system, prompt: prompt, schema: schema, maxTokens: maxTokens)
    }

    func generateJSON(system: String?, prompt: String, schema: String) async throws -> String {
        try await generateJSON(system: system, prompt: prompt, schema: schema, maxTokens: nil)
    }
}
