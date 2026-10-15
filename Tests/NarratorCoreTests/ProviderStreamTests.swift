import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import NarratorCore

private final class RecordedText: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

private final class FixtureProtocol: URLProtocol {
    struct Fixture: Sendable {
        var status: Int
        var chunks: [Data]
        var finish: Bool
        var onStop: (@Sendable () -> Void)?
    }
    final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var fixtures: [String: Fixture] = [:]
    }
    static let registry = Registry()
    private var fixture: Fixture?

    static func install(status: Int = 200, chunks: [Data], finish: Bool = true, onStop: (@Sendable () -> Void)? = nil) -> (URL, URLSessionConfiguration) {
        let url = URL(string: "https://\(UUID().uuidString.lowercased()).test")!
        registry.lock.withLock { registry.fixtures[url.host!] = Fixture(status: status, chunks: chunks, finish: finish, onStop: onStop) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        return (url, configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.registry.lock.withLock { Self.registry.fixtures.removeValue(forKey: request.url!.host!)! }
        self.fixture = fixture
        client!.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        for chunk in fixture.chunks { client!.urlProtocol(self, didLoad: chunk) }
        if fixture.finish { client!.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { fixture?.onStop?() }
}

private func sse(_ object: [String: Any]) throws -> String {
    "data: " + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n\n"
}

@Test func openAIStreamsCumulativeTextAcrossNetworkChunks() async throws {
    let events = try sse(["choices": [["delta": ["role": "assistant"]]]])
        + sse(["choices": [["delta": ["content": "`"]]]])
        + sse(["choices": [["delta": ["content": "``json\n{\"字\":"]]]])
        + sse(["choices": [["delta": ["content": "true}\n```"]]]])
        + "data: [DONE]\n\ndata: invalid and ignored\n\n"
    let data = Data(events.utf8)
    let (url, configuration) = FixtureProtocol.install(chunks: data.map { Data([$0]) })
    let received = RecordedText()
    let client = OpenAIChatClient(baseURL: url, path: "v1/chat/completions", model: "fixture", configuration: configuration)
    let json = try await client.generateJSON(system: nil, prompt: "", schema: "{}", maxTokens: nil) {
        received.append($0); return true
    }
    #expect(json == #"{"字":true}"#)
    #expect(received.all == ["", #"{"字":"#, #"{"字":true}"#])
}

@Test func openAINonStreamingCleansFencesAndRejectsMissingContent() async throws {
    let body = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "```json\n{\"ok\":true}\n```"]]]])
    let (url, configuration) = FixtureProtocol.install(chunks: [body.prefix(10), body.dropFirst(10)])
    let client = OpenAIChatClient(baseURL: url, path: "chat/completions", model: "fixture", stream: false, configuration: configuration)
    #expect(try await client.generateJSON(system: nil, prompt: "", schema: "{}") == #"{"ok":true}"#)
    let (emptyURL, emptyConfiguration) = FixtureProtocol.install(chunks: [Data(#"{"choices":[]}"#.utf8)])
    let empty = OpenAIChatClient(baseURL: emptyURL, path: "chat/completions", model: "fixture", stream: false, configuration: emptyConfiguration)
    await #expect(throws: HTTPClientError.self) { try await empty.generateJSON(system: nil, prompt: "", schema: "{}") }
}

@Test func streamExposesHTTPErrorBodyAndAPIError() async throws {
    let (url, configuration) = FixtureProtocol.install(status: 429, chunks: [Data("rate ".utf8), Data("limited".utf8)])
    let client = OpenAIChatClient(baseURL: url, path: "chat/completions", model: "fixture", configuration: configuration)
    do {
        _ = try await client.generateJSON(system: nil, prompt: "", schema: "{}")
        Issue.record("Expected HTTP error")
    } catch HTTPClientError.status(let code, let body) {
        #expect(code == 429)
        #expect(body == "rate limited")
    }
    let (errorURL, errorConfiguration) = FixtureProtocol.install(chunks: [Data(try sse(["error": ["message": "provider failed"]]).utf8)])
    let errorClient = OpenAIChatClient(baseURL: errorURL, path: "chat/completions", model: "fixture", configuration: errorConfiguration)
    do {
        _ = try await errorClient.generateJSON(system: nil, prompt: "", schema: "{}")
        Issue.record("Expected API error")
    } catch HTTPClientError.remote(let message) { #expect(message == "provider failed") }
}

@Test func partialFalseCancelsGeneration() async throws {
    let event = try sse(["choices": [["delta": ["content": "{"]]]])
    let (stopped, continuation) = AsyncStream<Void>.makeStream()
    let (url, configuration) = FixtureProtocol.install(chunks: [Data(event.utf8), Data(event.utf8)], finish: false) {
        continuation.yield(())
        continuation.finish()
    }
    let client = OpenAIChatClient(baseURL: url, path: "chat/completions", model: "fixture", configuration: configuration)
    let received = RecordedText()
    await #expect(throws: CancellationError.self) {
        try await client.generateJSON(system: nil, prompt: "", schema: "{}", maxTokens: nil) {
            received.append($0); return false
        }
    }
    #expect(received.all == ["{"])
    var iterator = stopped.makeAsyncIterator()
    #expect(await iterator.next() != nil)
}

@Test func anthropicStreamsOnlyEmitToolJSON() async throws {
    let events = try sse(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]])
        + sse(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "ignored"]])
        + sse(["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "name": "emit", "input": [:]]])
        + sse(["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": "{\"ok\":"]])
        + sse(["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": "true}"]])
        + sse(["type": "message_stop"])
    let bytes = Data(events.utf8)
    let (url, configuration) = FixtureProtocol.install(chunks: stride(from: 0, to: bytes.count, by: 11).map { Data(bytes[$0..<min($0 + 11, bytes.count)]) })
    let received = RecordedText()
    let client = AnthropicClient(baseURL: url, model: "fixture", configuration: configuration)
    #expect(try await client.generateJSON(system: nil, prompt: "", schema: "{}", maxTokens: nil) {
        received.append($0); return true
    } == #"{"ok":true}"#)
    #expect(received.all == [#"{"ok":"#, #"{"ok":true}"#])
}

@Test func anthropicNonStreamingExtractsToolInputAndStreamingErrorsSurface() async throws {
    let (url, configuration) = FixtureProtocol.install(chunks: [Data(#"{"content":[{"type":"text","text":"ignored"},{"type":"tool_use","name":"emit","input":{"ok":true}}]}"#.utf8)])
    let client = AnthropicClient(baseURL: url, model: "fixture", stream: false, configuration: configuration)
    let json = try await client.generateJSON(system: nil, prompt: "", schema: "{}")
    #expect(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Bool] == ["ok": true])
    let (errorURL, errorConfiguration) = FixtureProtocol.install(chunks: [Data(try sse(["type": "error", "error": ["message": "overloaded"]]).utf8)])
    let errorClient = AnthropicClient(baseURL: errorURL, model: "fixture", configuration: errorConfiguration)
    await #expect(throws: HTTPClientError.self) { try await errorClient.generateJSON(system: nil, prompt: "", schema: "{}") }
    let (cancelURL, cancelConfiguration) = FixtureProtocol.install(chunks: [Data((try sse(["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "name": "emit", "input": [:]]]) + sse(["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": "{"]])).utf8)])
    let cancelClient = AnthropicClient(baseURL: cancelURL, model: "fixture", configuration: cancelConfiguration)
    await #expect(throws: CancellationError.self) {
        try await cancelClient.generateJSON(system: nil, prompt: "", schema: "{}", maxTokens: nil, partial: { _ in false })
    }
}

@Test func modelsEndpointParsesOpenAIList() async throws {
    let (url, configuration) = FixtureProtocol.install(chunks: [Data(#"{"data":[{"id":"z"},{"id":"a"}]}"#.utf8)])
    let selection = ProviderConfiguration(presetID: "custom-openai", baseURL: url.absoluteString)
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    #expect(try await selection.fetchModels(key: "secret", session: session) == ["a", "z"])
}
